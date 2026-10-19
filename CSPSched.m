// CSPSched.m -- processes: the scheduler, and the thread-per-process
// fallback. See words.txt, The scheduler and The hazards.
//
// Scheduler. Each process is a coroutine: its own stack and saved
// registers. A few worker threads, one per core, run them. A process that
// parks switches back to its worker's loop, which runs the next runnable
// one; unparking puts a process back on the run queue. Nothing here
// enters the kernel unless a worker has nothing to do.
//
// Parking is committed by the worker after the switch, never by the
// process itself: until its registers are saved a process must not be
// resumed anywhere else. waiter->parkState settles the race with an
// unpark that arrives early: 0 not parked yet, 1 parked, 2 woken.
//
// Thread mode -- CSP_DEBUG=threads, a CPU without a context switch here
// yet, or a failed startup check -- runs each process as a thread, and
// parking is a semaphore wait.
//
// Locks: schedMu guards the run queue, the timers, the worker counts and
// mainWaiter; allMu guards the list of live processes. Neither is held
// while a process runs.

#import "CSP.h"
#import "CSPSched.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <pthread.h>
#import <signal.h>
#import <sys/mman.h>
#import <time.h>
#import <unistd.h>

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *pool);
void csp_switch(void **save, void *next);
void csp_start(void);

#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define CSP_TSAN 1
void *__tsan_get_current_fiber(void);
void *__tsan_create_fiber(unsigned flags);
void __tsan_destroy_fiber(void *fiber);
void __tsan_switch_to_fiber(void *fiber, unsigned flags);
#endif
#endif

enum { PARK = 1, YIELD, EXIT };                  // why a process switched out
enum { RUNNABLE = 1, RUNNING, WAITING };         // for the dump

typedef struct CSPWorker CSPWorker;

struct CSPProc {
    void *sp;                        // saved stack pointer while switched out
    char *stack;                     // the mapping: guard page, then stack
    size_t mapped;
    void *pool;                      // its autorelease pool stack while switched out
    pthread_t poolThread;            // the thread its pool pages belong to
    void *block;                     // the block to run, retained
    int action;
    void *parking;                   // its CSPWaiter, while switching out to park
    CSPWorker *worker;               // the worker running it
    _Atomic int state;
    const char *waitingOn;
    long pid;
    const char *file, *what;
    int line;
    CSPProc *next;                   // run queue, or free list
    BOOL reclaimable;                // kept for reuse, its stack pages offered back
    CSPProc *prevLive, *nextLive;    // all live processes
#if CSP_TSAN
    void *fiber;
#endif
};

struct CSPWorker {
    void *sp;                        // its loop's stack pointer while a process runs
    CSPProc *_Atomic current;
    _Atomic unsigned long switches;  // for the monitor: has it moved on?
    unsigned long seen;
    BOOL helped;                     // the monitor already added a worker for this stall
    BOOL extra;                      // added by the monitor; retires when not needed
    BOOL retired;
    mach_port_t port;
    CSPWorker *next;
#if CSP_TSAN
    void *fiber;
#endif
};

static BOOL schedOn;                 // set once at startup
static long maxprocs = 1;
static long poolSlot = -1;
static pthread_key_t workerKey;
static size_t pageSize;
static const size_t stackSize = 1 << 20;

static pthread_mutex_t schedMu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t workCond = PTHREAD_COND_INITIALIZER;
static CSPProc *runHead, *runTail;
static long nIdle, nAwake, nWorkers;
static long nStuck;                  // awake, but blocked in the kernel with a stand-in
static CSPWorker *workers;
static CSPProc *freeProcs;
static long nFreeProcs;
static void **freePools;
static long nFreePools, capFreePools;
static CSPWaiter *mainWaiter;        // main, parked with no timeout

typedef struct { uint64_t deadline; void *waiter; } Timer;
static Timer *heap;
static long nHeap, capHeap;

static pthread_mutex_t allMu = PTHREAD_MUTEX_INITIALIZER;
static CSPProc *liveProcs;
static long nextPid;

// Spinning: a worker that runs out of work, or a plain thread about to
// wait, keeps looking for a short while before sleeping in the kernel.
// In a busy program the next thing arrives within that window, and
// nothing sleeps or wakes. Bounded, and only right after there was work,
// so an idle program still sleeps completely.
enum { SPIN_NS = 50000 };
static _Atomic long nQueued;         // on the run queue; readable without the lock
static _Atomic long nSpinning;       // workers looking for work
static long maxSpinners = 1;

static void cpuRelax(void) {
#if defined(__x86_64__)
    __asm__ volatile("pause");
#endif
}

static pthread_cond_t monitorCond = PTHREAD_COND_INITIALIZER;
static _Atomic long nRunning;
static _Atomic int monitorSleeping;

static void *(*cxaGlobals)(void);

static uint64_t nowNs(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

static void fatal(const char *msg) {
    fputs(msg, stderr);
    abort();
}


// Thread slots. The autorelease pool's stack is one pointer in one of
// them; which one is found at startup.

#if defined(__x86_64__)
static void *getSlot(long k) {
    void *v;
    __asm__ volatile("movq %%gs:(,%1,8), %0" : "=r"(v) : "r"(k));
    return v;
}
static void setSlot(long k, void *v) {
    __asm__ volatile("movq %0, %%gs:(,%1,8)" : : "r"(v), "r"(k) : "memory");
}
#else
static void *getSlot(long k) { return NULL; }
static void setSlot(long k, void *v) {}
#endif

// Where a pool page keeps its thread and its links; found at startup.
static long pageThreadAt = -1, pageParentAt = -1, pageChildAt = -1;

// Hands every page of a pool stack to the calling thread. The runtime
// checks a page's thread when it frees the page, and a process's pages
// may have been made on another worker. 1 is the runtime's "pool open,
// no page yet".
static void adoptPoolPages(void *hot) {
    if ((uintptr_t)hot <= 1) return;
    pthread_t self = pthread_self();
    for (char *pg = hot; pg; pg = *(char **)(pg + pageParentAt))
        *(pthread_t *)(pg + pageThreadAt) = self;
    for (char *pg = *(char **)((char *)hot + pageChildAt); pg; pg = *(char **)(pg + pageChildAt))
        *(pthread_t *)(pg + pageThreadAt) = self;
}


// Waiters

@implementation CSPWaiter
@end

static CSPWorker *currentWorker(void) {
    // An opaque call, re-made every time: the compiler must not cache a
    // thread-local across a switch, because the process may continue on
    // another worker.
    return schedOn ? pthread_getspecific(workerKey) : NULL;
}

static CSPProc *currentProc(void) {
    CSPWorker *w = currentWorker();
    return w ? atomic_load(&w->current) : NULL;
}

CSPWaiter *CSPNewWaiter(const char *what) {
    CSPWaiter *w = [CSPWaiter new];
    atomic_init(&w->fired, -1);
    atomic_init(&w->parkState, 0);
    w->timerSlot = -1;
    w->what = what;
    w->proc = currentProc();
    if (!w->proc) w->sem = dispatch_semaphore_create(0);
    return w;
}


// The run queue

// Wakes a sleeping worker only if none is awake looking for work -- an
// awake one will find it, with no kernel call.
static void wakeWorker_locked(void) {
    if (nIdle > 0 && atomic_load(&nSpinning) == 0) pthread_cond_signal(&workCond);
}

static void pushRunnable_locked(CSPProc *p) {
    atomic_store(&p->state, RUNNABLE);
    p->next = NULL;
    if (runTail) runTail->next = p;
    else runHead = p;
    runTail = p;
    atomic_fetch_add(&nQueued, 1);
    wakeWorker_locked();
}

static CSPProc *popRunnable_locked(void) {
    CSPProc *p = runHead;
    if (p) {
        runHead = p->next;
        if (!runHead) runTail = NULL;
        atomic_fetch_sub(&nQueued, 1);
    }
    return p;
}

static void makeRunnable(CSPProc *p) {
    CSPLock(&schedMu);
    pushRunnable_locked(p);
    pthread_mutex_unlock(&schedMu);
}


// Timers: a heap of (deadline, waiter), earliest first. Each waiter knows
// its place, so a wait that ends early takes its timer out.

static void heapSet(long i, Timer t) {
    heap[i] = t;
    ((__bridge CSPWaiter *)t.waiter)->timerSlot = i;
}

static void heapSwap(long a, long b) {
    Timer t = heap[a];
    heapSet(a, heap[b]);
    heapSet(b, t);
}

static void heapUp(long i) {
    while (i > 0) {
        long parent = (i - 1) / 2;
        if (heap[parent].deadline <= heap[i].deadline) break;
        heapSwap(parent, i);
        i = parent;
    }
}

static void heapDown(long i) {
    for (;;) {
        long l = 2 * i + 1, r = l + 1, m = i;
        if (l < nHeap && heap[l].deadline < heap[m].deadline) m = l;
        if (r < nHeap && heap[r].deadline < heap[m].deadline) m = r;
        if (m == i) return;
        heapSwap(i, m);
        i = m;
    }
}

static void timerAdd_locked(CSPWaiter *w, uint64_t deadline) {
    if (nHeap == capHeap) {
        capHeap = capHeap ? 2 * capHeap : 64;
        heap = realloc(heap, capHeap * sizeof *heap);
    }
    heapSet(nHeap, (Timer){deadline, (__bridge_retained void *)w});
    nHeap++;
    heapUp(nHeap - 1);
    // A new earliest deadline: an idle worker re-times its sleep.
    if (w->timerSlot == 0 && nIdle > 0) pthread_cond_signal(&workCond);
}

static void timerRemove_locked(CSPWaiter *w) {
    long i = w->timerSlot;
    if (i < 0) return;
    void *gone = heap[i].waiter;
    nHeap--;
    if (i != nHeap) {
        heapSet(i, heap[nHeap]);         // the last one fills the hole, then
        heapUp(i);                       // moves up or down to its place
        heapDown(i);
    }
    w->timerSlot = -1;
    CFRelease(gone);
}

static void unpark_locked(CSPWaiter *w) {
    if (atomic_exchange(&w->parkState, 2) == 1) pushRunnable_locked(w->proc);
}

// Fires every timer that is due: each claims its waiter for the timeout
// case, unless something else claimed it first.
static void fireTimers_locked(uint64_t now) {
    while (nHeap && heap[0].deadline <= now) {
        CSPWaiter *w = (__bridge CSPWaiter *)heap[0].waiter;
        timerRemove_locked(w);
        long none = -1;
        if (atomic_compare_exchange_strong(&w->fired, &none, w->timerIndex)) unpark_locked(w);
    }
}


// The process dump and the deadlock report

static void dumpProcs(void) {
    CSPLock(&allMu);
    for (CSPProc *p = liveProcs; p; p = p->nextLive) {
        int s = atomic_load(&p->state);
        const char *state = s == RUNNING ? "running" : s == RUNNABLE ? "runnable" : "waiting";
        if (s == WAITING && p->waitingOn)
            fprintf(stderr, "process %ld [waiting in %s], started at %s:%d: %s\n",
                    p->pid, p->waitingOn, p->file, p->line, p->what);
        else
            fprintf(stderr, "process %ld [%s], started at %s:%d: %s\n",
                    p->pid, state, p->file, p->line, p->what);
    }
    pthread_mutex_unlock(&allMu);
}

// Deadlock: main waits on a channel with no timeout, nothing is runnable or
// running -- no worker awake, so none is stuck in a system call either --
// and no timer is pending. Nothing can ever happen again. (Threads the
// program starts itself, outside go(), are not counted; see words.txt.)
static void checkDeadlock_locked(void) {
    if (!mainWaiter || nAwake > 0 || runHead || nHeap) return;
    if (atomic_load(&mainWaiter->fired) != -1) return;
    fprintf(stderr, "ObjCSP: all processes are asleep -- deadlock!\n\nmain [waiting in %s]\n", mainWaiter->what);
    if (getenv("CSP_DEBUG") && strstr(getenv("CSP_DEBUG"), "sched"))
        fprintf(stderr, "(workers %ld, awake %ld, idle %ld, runnable %ld, timers %ld)\n",
                nWorkers, nAwake, nIdle, atomic_load(&nQueued), nHeap);
    dumpProcs();
    fflush(stderr);
    _exit(2);
}


// Parking

static void checkNotInCatch(void) {
    // Hazard 4: the runtime's record of exceptions being caught is per
    // thread, and a process could continue on another one.
    if (!cxaGlobals) return;
    struct { void *caught; unsigned uncaught; } *g = cxaGlobals();
    if (g && (g->caught || g->uncaught))
        fatal("ObjCSP: a channel operation inside @catch or @finally -- not allowed "
              "under the scheduler (see words.txt, The hazards)\n");
}

static void toScheduler(CSPProc *p, int action) {
    p->action = action;
    CSPWorker *w = p->worker;
#if CSP_TSAN
    __tsan_switch_to_fiber(w->fiber, 0);
#endif
    csp_switch(&p->sp, w->sp);
}

static void procPark(CSPProc *p, CSPWaiter *w) {
    checkNotInCatch();
    p->parking = (__bridge void *)w;
    p->waitingOn = w->what;
    toScheduler(p, PARK);
    p->waitingOn = NULL;
}

// A plain thread about to sleep: the claim is often moments away.
// Waiting for it here means the unpark finds no one asleep, and a
// semaphore signal with no sleeper never enters the kernel.
static void spinForClaim(CSPWaiter *w) {
    if (!schedOn) return;                        // thread mode stays as it was
    uint64_t until = nowNs() + SPIN_NS;
    while (atomic_load(&w->fired) == -1 && nowNs() < until) cpuRelax();
}

void CSPPark(CSPWaiter *w) {
    if (w->proc) {
        procPark(w->proc, w);
        return;
    }
    spinForClaim(w);
    BOOL isMain = schedOn && pthread_main_np();
    if (isMain) {
        CSPLock(&schedMu);
        mainWaiter = w;
        checkDeadlock_locked();
        pthread_mutex_unlock(&schedMu);
    }
    dispatch_semaphore_wait(w->sem, DISPATCH_TIME_FOREVER);
    if (isMain) {
        CSPLock(&schedMu);
        mainWaiter = nil;
        pthread_mutex_unlock(&schedMu);
    }
}

void CSPParkFor(CSPWaiter *w, long timeoutIndex, double seconds) {
    seconds = seconds > 0 ? MIN(seconds, 1e9) : 0;
    if (w->proc) {
        w->timerIndex = timeoutIndex;
        CSPLock(&schedMu);
        timerAdd_locked(w, nowNs() + (uint64_t)(seconds * 1e9));
        pthread_mutex_unlock(&schedMu);
        procPark(w->proc, w);
        CSPLock(&schedMu);
        timerRemove_locked(w);                 // still there if a channel won
        pthread_mutex_unlock(&schedMu);
        return;
    }
    spinForClaim(w);
    dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(w->sem, t) != 0) {
        // Timed out -- unless something claimed us meanwhile, in which
        // case its unpark is on the way.
        long none = -1;
        if (!atomic_compare_exchange_strong(&w->fired, &none, timeoutIndex))
            dispatch_semaphore_wait(w->sem, DISPATCH_TIME_FOREVER);
    }
}

void CSPUnpark(CSPWaiter *w) {
    if (!w->proc) {
        dispatch_semaphore_signal(w->sem);
        return;
    }
    if (atomic_exchange(&w->parkState, 2) == 1) makeRunnable(w->proc);
}

void sleepFor(double seconds) {
    CSPParkFor(CSPNewWaiter("sleepFor"), 0, seconds);
}

void yield(void) {
    CSPProc *p = currentProc();
    if (p) toScheduler(p, YIELD);
    else sched_yield();
}


// Processes: stacks, start, finish

__attribute__((unused))           // on CPUs without a context switch here yet
static void procEntry(CSPProc *p) {
    @autoreleasepool {
        void (^block)(void) = (__bridge_transfer id)p->block;
        p->block = NULL;
        block();
    }                                // the block and what it captured are released here
    toScheduler(p, EXIT);
}

static CSPProc *procNew(void) {
    CSPProc *p = NULL;
    void *pool = NULL;
    CSPLock(&schedMu);
    if (freeProcs) {
        p = freeProcs;
        freeProcs = p->next;
        nFreeProcs--;
    } else if (nFreePools) {
        pool = freePools[--nFreePools];
    }
    pthread_mutex_unlock(&schedMu);
    if (p && p->reclaimable) {
        madvise(p->stack + pageSize, stackSize, MADV_FREE_REUSE);
        p->reclaimable = NO;
    }

    if (!p) {
        p = calloc(1, sizeof *p);
        p->mapped = stackSize + pageSize;
        p->stack = mmap(NULL, p->mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p->stack == MAP_FAILED) {
            free(p);
            [NSException raise:NSInternalInconsistencyException format:@"go: no memory for a process stack"];
        }
        mprotect(p->stack, pageSize, PROT_NONE);          // the guard page
        p->pool = pool;
#if CSP_TSAN
        p->fiber = __tsan_create_fiber(0);
#endif
    }

    // A first switch into the process lands in csp_start, which calls
    // procEntry(p); see csp_x86_64.S.
#if defined(__x86_64__)
    uintptr_t *top = (uintptr_t *)(p->stack + p->mapped);
    uint32_t ctl[2];
    __asm__ volatile("stmxcsr (%0); fnstcw 4(%0)" : : "r"(ctl) : "memory");
    *--top = 0;
    *--top = (uintptr_t)csp_start;
    *--top = 0;                                  // rbp
    *--top = 0;                                  // rbx
    *--top = (uintptr_t)p;                       // r12
    *--top = (uintptr_t)procEntry;               // r13
    *--top = 0;                                  // r14
    *--top = 0;                                  // r15
    *--top = ((uintptr_t)ctl[1] << 32) | ctl[0];
    p->sp = top;
#endif
    p->action = 0;
    p->waitingOn = NULL;
    return p;
}

// Finished stacks kept exactly as they are; past this many, their pages
// are offered back. Keeping every one was ~6% faster on a benchmark with
// 20,000 processes coming and going, but holds their memory for good.
#ifndef CSP_HOT_STACKS
#define CSP_HOT_STACKS 1024
#endif

static void procFinished(CSPProc *p) {
    CSPLock(&allMu);
    if (p->prevLive) p->prevLive->nextLive = p->nextLive;
    else liveProcs = p->nextLive;
    if (p->nextLive) p->nextLive->prevLive = p->prevLive;
    pthread_mutex_unlock(&allMu);

    // Kept for reuse, stack and all. Giving a stack back to the kernel
    // (munmap) makes every other core running this program drop its cached
    // view of that memory -- an interrupt to each of them -- and a program
    // with thousands of processes coming and going spent much of its time
    // there. So stacks stay mapped: the first 1,024 as they are, the rest
    // with their pages offered back to the kernel (as malloc does), so
    // memory stays bounded. Only past 65,536 is a stack unmapped -- the
    // pool stack is kept even then; the runtime has no way to free one.
    CSPLock(&schedMu);
    long kept = nFreeProcs;
    if (kept < 65536) {
        p->next = freeProcs;
        freeProcs = p;
        nFreeProcs++;
        pthread_mutex_unlock(&schedMu);
        if (kept >= CSP_HOT_STACKS) {
            madvise(p->stack + pageSize, stackSize, MADV_FREE_REUSABLE);
            p->reclaimable = YES;
        }
        return;
    }
    if (p->pool) {
        if (nFreePools == capFreePools) {
            capFreePools = capFreePools ? 2 * capFreePools : 64;
            freePools = realloc(freePools, capFreePools * sizeof *freePools);
        }
        freePools[nFreePools++] = p->pool;
    }
    pthread_mutex_unlock(&schedMu);
    munmap(p->stack, p->mapped);
#if CSP_TSAN
    __tsan_destroy_fiber(p->fiber);
#endif
    free(p);
}


// Workers

static void runProc(CSPWorker *w, CSPProc *p) {
    p->worker = w;
    atomic_store(&p->state, RUNNING);
    atomic_store(&w->current, p);
    atomic_fetch_add(&w->switches, 1);
    // Each process has its own autorelease pool stack; see words.txt. If it
    // last ran on another thread, its pages move to this one.
    pthread_t self = pthread_self();
    if (p->poolThread != self) {
        adoptPoolPages(p->pool);
        p->poolThread = self;
    }
    void *mine = getSlot(poolSlot);
    setSlot(poolSlot, p->pool);
#if CSP_TSAN
    __tsan_switch_to_fiber(p->fiber, 0);
#endif
    csp_switch(&w->sp, p->sp);
    p->pool = getSlot(poolSlot);
    setSlot(poolSlot, mine);
    atomic_store(&w->current, NULL);
}

// After a process switched out: commit its park, requeue it, or finish it.
static void afterSwitch(CSPProc *p) {
    switch (p->action) {
    case PARK: {
        CSPWaiter *__unsafe_unretained w = (__bridge CSPWaiter *)p->parking;
        p->parking = NULL;
        atomic_store(&p->state, WAITING);
        int notYet = 0;
        // Once committed, p belongs to whoever unparks it: don't touch it.
        if (!atomic_compare_exchange_strong(&w->parkState, &notYet, 1)) makeRunnable(p);
        break;
    }
    case YIELD:
        makeRunnable(p);
        break;
    case EXIT:
        procFinished(p);
        break;
    }
}

static void noteRunning(void) {
    if (atomic_fetch_add(&nRunning, 1) == 0 && atomic_load(&monitorSleeping)) {
        CSPLock(&schedMu);
        pthread_cond_signal(&monitorCond);
        pthread_mutex_unlock(&schedMu);
    }
}

static void *workerMain(void *arg) {
    CSPWorker *w = arg;
    pthread_setspecific(workerKey, w);
    w->port = pthread_mach_thread_np(pthread_self());
#if CSP_TSAN
    w->fiber = __tsan_get_current_fiber();
#endif
    // The stack-overflow handler runs on its own stack: the process's is full.
    stack_t signalStack = {.ss_sp = malloc(128 * 1024), .ss_size = 128 * 1024, .ss_flags = 0};
    sigaltstack(&signalStack, NULL);

    CSPLock(&schedMu);
    for (;;) {
        if (w->extra && nAwake - nStuck > maxprocs) {    // the stall that called for it is over
            w->retired = YES;
            nAwake--;
            nWorkers--;
            pthread_mutex_unlock(&schedMu);
            return NULL;
        }
        fireTimers_locked(nowNs());
        CSPProc *p = popRunnable_locked();
        if (p) {
            // More waiting: make sure another worker is coming for it.
            // Each woken worker does the same, so a burst of work fans out
            // across the cores.
            if (runHead) wakeWorker_locked();
            pthread_mutex_unlock(&schedMu);
            noteRunning();
            runProc(w, p);
            atomic_fetch_sub(&nRunning, 1);
            afterSwitch(p);
            CSPLock(&schedMu);
            if (w->helped) {                             // back from the kernel
                w->helped = NO;
                nStuck--;
            }
            continue;
        }
        if (atomic_load(&nSpinning) < maxSpinners) {
            // Nothing to run: look again for a moment before sleeping.
            atomic_fetch_add(&nSpinning, 1);
            pthread_mutex_unlock(&schedMu);
            uint64_t until = nowNs() + SPIN_NS;
            while (atomic_load(&nQueued) == 0 && nowNs() < until) cpuRelax();
            atomic_fetch_sub(&nSpinning, 1);
            CSPLock(&schedMu);
            if (runHead) continue;
        }
        nIdle++;
        nAwake--;
        checkDeadlock_locked();
        if (nHeap) {
            uint64_t now = nowNs(), due = heap[0].deadline;
            uint64_t wait = due > now ? due - now : 0;
            struct timespec ts = {(time_t)(wait / 1000000000), (long)(wait % 1000000000)};
            pthread_cond_timedwait_relative_np(&workCond, &schedMu, &ts);
        } else {
            pthread_cond_wait(&workCond, &schedMu);
        }
        nIdle--;
        nAwake++;
    }
}

static void startWorker_locked(BOOL extra) {
    CSPWorker *w = NULL;
    for (CSPWorker *r = workers; r; r = r->next)
        if (r->retired) { w = r; break; }
    if (!w) {
        w = calloc(1, sizeof *w);
        w->next = workers;
        workers = w;
    }
    w->extra = extra;
    w->retired = NO;
    w->helped = NO;
    nWorkers++;
    nAwake++;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t t;
    if (pthread_create(&t, &attr, workerMain, w) != 0) fatal("ObjCSP: can't start a worker thread\n");
    pthread_attr_destroy(&attr);
}


// The monitor -- hazards 2 and 8. While any process runs, every 10 ms:
// a worker still on the same process as last time, whose thread the kernel
// says is waiting (a file read, sleep, a lock), gets a stand-in, so the
// runnable processes keep going. A worker that is computing is left
// alone: it is using its core. When nothing runs, the monitor sleeps.

static BOOL threadWaiting(mach_port_t port) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
    if (thread_info(port, THREAD_BASIC_INFO, (thread_info_t)&info, &n) != KERN_SUCCESS) return NO;
    return info.run_state == TH_STATE_WAITING || info.run_state == TH_STATE_UNINTERRUPTIBLE;
}

static void *monitorMain(void *arg) {
    for (;;) {
        CSPLock(&schedMu);
        for (;;) {
            atomic_store(&monitorSleeping, 1);
            if (atomic_load(&nRunning) > 0) break;
            pthread_cond_wait(&monitorCond, &schedMu);
        }
        atomic_store(&monitorSleeping, 0);
        pthread_mutex_unlock(&schedMu);

        usleep(10000);

        CSPLock(&schedMu);
        for (CSPWorker *w = workers; w; w = w->next) {
            if (w->retired) continue;
            unsigned long s = atomic_load(&w->switches);
            CSPProc *p = atomic_load(&w->current);
            if (s != w->seen) {
                w->seen = s;
            } else if (p && !w->helped && runHead && nIdle == 0 && nWorkers < 1024 && threadWaiting(w->port)) {
                w->helped = YES;                         // it clears this itself when it's back
                nStuck++;
                startWorker_locked(YES);
            }
        }
        pthread_mutex_unlock(&schedMu);
    }
    return NULL;
}


// A stack overflow lands in a process's guard page: say so.

static struct sigaction oldSegv, oldBus;

static void onFault(int sig, siginfo_t *info, void *ctx) {
    CSPWorker *w = schedOn ? pthread_getspecific(workerKey) : NULL;
    CSPProc *p = w ? atomic_load(&w->current) : NULL;
    char *a = info->si_addr;
    if (p && a >= p->stack && a < p->stack + pageSize) {
        static const char msg[] = "ObjCSP: process stack overflow (1 MB) -- started at ";
        write(2, msg, sizeof msg - 1);
        write(2, p->file, strlen(p->file));
        char line[24];
        int n = snprintf(line, sizeof line, ":%d: ", p->line);
        write(2, line, n);
        write(2, p->what, strlen(p->what));
        write(2, "\n", 1);
        abort();
    }
    // Not ours: put the old handler back and let the fault happen again.
    sigaction(sig, sig == SIGSEGV ? &oldSegv : &oldBus, NULL);
}


// Startup

#if defined(__x86_64__)
// Finds the slot holding the autorelease pool's stack, on a throwaway
// thread so a wrong guess can only break that thread: open a pool and
// autorelease something, then open another -- its token is an address in
// the pool's current page, and the slot is the one holding the start of
// that page. Exactly one match, then prove that swapping it swaps pools.
static void *probePoolSlot(void *arg) {
    long *result = arg;
    enum { N = 256 };
    void *before[N];
    for (long k = 0; k < N; k++) before[k] = getSlot(k);

    void *outer = objc_autoreleasePoolPush();
    __weak id watched = nil;
    {
        NSObject *o = [NSObject new];
        watched = o;
        CFAutorelease(CFBridgingRetain(o));
    }
    void *token = objc_autoreleasePoolPush();
    long found = -1, matches = 0;
    for (long k = 0; k < N; k++) {
        uintptr_t v = (uintptr_t)getSlot(k);
        if (!before[k] && v && (uintptr_t)token > v && (uintptr_t)token < v + 64 * 1024) {
            found = k;
            matches++;
        }
    }
    objc_autoreleasePoolPop(token);
    if (matches != 1) {
        objc_autoreleasePoolPop(outer);
        return NULL;
    }

    void *mine = getSlot(found);
    setSlot(found, NULL);                        // an empty pool stack of its own
    void *inner = objc_autoreleasePoolPush();
    CFAutorelease(CFBridgingRetain([NSObject new]));
    objc_autoreleasePoolPop(inner);
    void *other = getSlot(found);
    setSlot(found, mine);

    // Each pool page records the thread that made it, and the runtime
    // checks that when it frees the page. Find that field, and the links
    // to a page's parent and child, so a process's pages can be handed to
    // whichever thread it continues on: fill the first page until a second
    // one starts, then each field must match in exactly one place.
    char *page1 = getSlot(found);
    while (getSlot(found) == page1) CFAutorelease(CFBridgingRetain([NSObject new]));
    char *page2 = getSlot(found);
    uintptr_t self = (uintptr_t)pthread_self();
    long threadAt = -1, parentAt = -1, childAt = -1, nThread = 0, nParent = 0, nChild = 0;
    for (long off = 16; off <= 80; off += 8) {
        uintptr_t in1 = *(uintptr_t *)(page1 + off), in2 = *(uintptr_t *)(page2 + off);
        if (in1 == self && in2 == self) { threadAt = off; nThread++; }
        if (in1 == 0 && in2 == (uintptr_t)page1) { parentAt = off; nParent++; }
        if (in1 == (uintptr_t)page2 && in2 == 0) { childAt = off; nChild++; }
    }
    objc_autoreleasePoolPop(outer);              // the original pool, intact

    if (!watched && other && other != mine && nThread == 1 && nParent == 1 && nChild == 1) {
        *result = found;
        pageThreadAt = threadAt;
        pageParentAt = parentAt;
        pageChildAt = childAt;
        CSPLock(&schedMu);            // reused by the first process
        capFreePools = 64;
        freePools = malloc(capFreePools * sizeof *freePools);
        freePools[nFreePools++] = other;
        pthread_mutex_unlock(&schedMu);
    }
    return NULL;
}

static long findPoolSlot(void) {
    long slot = -1;
    pthread_t t;
    if (pthread_create(&t, NULL, probePoolSlot, &slot) != 0) return -1;
    pthread_join(t, NULL);
    return slot;
}
#endif

__attribute__((unused))
static void startScheduler(void) {
    pthread_key_create(&workerKey, NULL);
    cxaGlobals = (void *(*)(void))dlsym(RTLD_DEFAULT, "__cxa_get_globals");

    struct sigaction sa = {0};
    sa.sa_sigaction = onFault;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &oldSegv);
    sigaction(SIGBUS, &sa, &oldBus);

    schedOn = YES;
    maxSpinners = maxprocs > 1 ? maxprocs / 2 : 1;
    CSPLock(&schedMu);
    for (long i = 0; i < maxprocs; i++) startWorker_locked(NO);
    pthread_mutex_unlock(&schedMu);

    pthread_t t;
    pthread_create(&t, NULL, monitorMain, NULL);
    pthread_detach(t);
}

static void installQuitDump(void) {
    static dispatch_source_t source;
    signal(SIGQUIT, SIG_IGN);
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGQUIT, 0,
                                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(source, ^{
        fprintf(stderr, "ObjCSP: SIGQUIT\n\n");
        if (schedOn) dumpProcs();
        else fprintf(stderr, "(the process dump needs the scheduler; this run is CSP_DEBUG=threads)\n");
        fflush(stderr);
        _exit(2);
    });
    dispatch_resume(source);
}

static void schedInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Foundation assumes it is single-threaded until an NSThread has
        // been started; start one so it locks properly around our threads.
        [NSThread detachNewThreadWithBlock:^{}];
        pageSize = (size_t)getpagesize();

        const char *n = getenv("CSP_MAXPROCS");
        maxprocs = n && atol(n) > 0 ? atol(n) : (long)NSProcessInfo.processInfo.activeProcessorCount;
        const char *debug = getenv("CSP_DEBUG");
        BOOL threads = debug && strstr(debug, "threads");
        (void)threads;                           // unused where there's no scheduler yet

#if defined(__x86_64__)
        if (!threads) {
            poolSlot = findPoolSlot();
            if (poolSlot >= 0)
                startScheduler();
            else
                fputs("ObjCSP: couldn't find the autorelease pool's thread slot -- "
                      "running a thread per process\n", stderr);
        }
#endif
        installQuitDump();
    });
}

// For tests and the benchmark: which way processes run.
const char *CSPMode(void) {
    schedInit();
    return schedOn ? "scheduler" : "threads";
}

long CSPMaxProcs(void) {
    schedInit();
    return maxprocs;
}


// go

static void *runThread(void *arg) {
    @autoreleasepool {
        void (^block)(void) = (__bridge_transfer id)arg;
        block();
    }
    return NULL;
}

static void goThread(void (^block)(void)) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    void *arg = (__bridge_retained void *)[block copy];
    pthread_t thread;
    int err = pthread_create(&thread, &attr, runThread, arg);
    pthread_attr_destroy(&attr);
    if (err) {
        CFRelease(arg);
        [NSException raise:NSInternalInconsistencyException
                    format:@"go: can't start a process: %s (macOS allows 2,048 threads per program)",
                           strerror(err)];
    }
}

void CSPGo(const char *file, int line, const char *what, void (^block)(void)) {
    schedInit();
    if (!schedOn) {
        goThread(block);
        return;
    }
    CSPProc *p = procNew();
    p->block = (__bridge_retained void *)[block copy];
    p->file = file;
    p->line = line;
    p->what = what;
    CSPLock(&allMu);
    p->pid = ++nextPid;
    p->prevLive = NULL;
    p->nextLive = liveProcs;
    if (liveProcs) liveProcs->prevLive = p;
    liveProcs = p;
    pthread_mutex_unlock(&allMu);
    makeRunnable(p);
}
