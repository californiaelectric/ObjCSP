// Spike: can coroutines that interleave and move between threads keep
// correct autorelease pools, if each gets its own pool stack?
#import <Foundation/Foundation.h>
#import <pthread.h>
#import <sys/mman.h>
#import <time.h>

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);
void csp_switch(void **save, void *next);
void csp_start(void);

enum { POOL_SLOT = 43 };       // found by findslot.m
static void *getPool(void) { void *v; __asm__ volatile("movq %%gs:(,%1,8), %0" : "=r"(v) : "r"((long)POOL_SLOT)); return v; }
static void setPool(void *v) { __asm__ volatile("movq %0, %%gs:(,%1,8)" : : "r"(v), "r"((long)POOL_SLOT) : "memory"); }

static BOOL swapPools;

typedef struct Co {
    void *sp;            // saved stack pointer while suspended
    void *back;          // the resumer's stack pointer while running
    void *pool;          // this coroutine's pool stack while suspended
    void *stack;
    void (*fn)(struct Co *);
    BOOL done;
    long step;
} Co;

static void entry(Co *co) {
    co->fn(co);
    co->done = YES;
    csp_switch(&co->sp, co->back);   // never resumed again
}

static Co *coNew(void (*fn)(Co *)) {
    enum { SIZE = 256 * 1024 };
    Co *co = calloc(1, sizeof *co);
    co->stack = mmap(NULL, SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    mprotect(co->stack, 4096, PROT_NONE);                       // guard page
    co->fn = fn;
    uintptr_t *top = (uintptr_t *)((char *)co->stack + SIZE);   // 16-aligned
    uint32_t ctl[2];
    __asm__ volatile("stmxcsr (%0); fnstcw 4(%0)" : : "r"(ctl) : "memory");
    *--top = 0;                        // so csp_start runs with call alignment
    *--top = (uintptr_t)csp_start;     // csp_switch's ret lands here
    *--top = 0;                        // rbp
    *--top = 0;                        // rbx
    *--top = (uintptr_t)co;            // r12: arg
    *--top = (uintptr_t)entry;         // r13: fn
    *--top = 0;                        // r14
    *--top = 0;                        // r15
    *--top = ((uintptr_t)ctl[1] << 32) | ctl[0];
    co->sp = top;
    return co;
}

// Run co until it yields; on whatever thread calls this.
static void resume(Co *co) {
    void *mine = NULL;
    if (swapPools) { mine = getPool(); setPool(co->pool); }
    csp_switch(&co->back, co->sp);
    if (swapPools) { co->pool = getPool(); setPool(mine); }
}

static void yield(Co *co) {
    csp_switch(&co->sp, co->back);
}

// --- the interleaving test --------------------------------------------

enum { OBJS = 3000 };          // several pool pages' worth per pool

static int failures;
#define EXPECT(cond, ...) do { if (!(cond)) { failures++; printf("    BROKEN: " __VA_ARGS__); printf("\n"); } } while (0)

static int alive(__weak id *w, int n) { int k = 0; for (int i = 0; i < n; i++) if (w[i]) k++; return k; }

// Each coroutine: outer pool, objects, yield; inner pool, objects, yield;
// pop inner, yield; pop outer. Between every step the other coroutine runs,
// often on a different thread.
typedef struct { __weak id outer[OBJS]; __weak id inner[OBJS]; } Watch;
static Watch watchA, watchB;

static void fill(__weak id *w) {
    for (int i = 0; i < OBJS; i++) {
        NSObject *o = [NSObject new];
        w[i] = o;
        CFAutorelease(CFBridgingRetain(o));
    }
}

static void body(Co *co, Watch *w) {
    void *outer = objc_autoreleasePoolPush();
    fill(w->outer);
    yield(co);
    void *inner = objc_autoreleasePoolPush();
    fill(w->inner);
    yield(co);
    objc_autoreleasePoolPop(inner);
    yield(co);
    objc_autoreleasePoolPop(outer);
}
static void bodyA(Co *co) { body(co, &watchA); }
static void bodyB(Co *co) { body(co, &watchB); }

// Steps run on alternating threads: each step is a fresh pthread that
// resumes one coroutine once and exits.
typedef struct { Co *co; } Step;
static void *stepThread(void *arg) { resume(((Step *)arg)->co); return NULL; }
static void onNewThread(Co *co) {
    Step s = {co};
    pthread_t t;
    pthread_create(&t, NULL, stepThread, &s);
    pthread_join(t, NULL);
}

static void check(const char *when, int aOuter, int aInner, int bOuter, int bInner) {
    int ao = alive(watchA.outer, OBJS), ai = alive(watchA.inner, OBJS);
    int bo = alive(watchB.outer, OBJS), bi = alive(watchB.inner, OBJS);
    EXPECT(ao == aOuter && ai == aInner && bo == bOuter && bi == bInner,
           "%s: alive A outer %d inner %d, B outer %d inner %d (expected %d %d %d %d)",
           when, ao, ai, bo, bi, aOuter, aInner, bOuter, bInner);
}

static void interleave(BOOL crossThreads) {
    Co *a = coNew(bodyA), *b = coNew(bodyB);
    void (*run)(Co *) = crossThreads ? onNewThread : resume;
    int N = OBJS;
    run(a); check("A opened outer", N, 0, 0, 0);
    run(b); check("B opened outer", N, 0, N, 0);
    run(a); check("A opened inner", N, N, N, 0);
    run(b); check("B opened inner", N, N, N, N);
    run(a); check("A popped inner", N, 0, N, N);
    run(b); check("B popped inner", N, 0, N, 0);
    run(a); check("A popped outer", 0, 0, N, 0);
    run(b); check("B popped outer", 0, 0, 0, 0);
    EXPECT(a->done && b->done, "coroutines didn't finish");
}

// --- switch timing ------------------------------------------------------

static void pingBody(Co *co) { for (;;) yield(co); }

static double timeSwitches(BOOL swap) {
    swapPools = swap;
    Co *co = coNew(pingBody);
    enum { ROUNDS = 5000000 };
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < ROUNDS; i++) resume(co);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    return ns / ROUNDS / 2;                 // two switches per round trip
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "all";
    @autoreleasepool {
        if (!strcmp(mode, "noswap")) {
            swapPools = NO;
            printf("same thread, pools NOT swapped:\n");
            interleave(NO);
            printf("  %s\n", failures ? "broken, as expected" : "no failure seen");
            return 0;
        }
        swapPools = YES;
        for (int round = 0; round < 50; round++) {
            interleave(NO);
            interleave(YES);
        }
        printf("pools swapped: 50 rounds same-thread + 50 rounds across threads, %d failures\n", failures);
        printf("switch cost: %.1f ns without pool swap, %.1f ns with\n", timeSwitches(NO), timeSwitches(YES));
    }
    return failures ? 1 : 0;
}
