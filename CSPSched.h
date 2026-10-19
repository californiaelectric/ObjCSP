// CSPSched.h -- internal to the library: how a waiting process sleeps
// and wakes. The channel code (CSP.m) uses only this; CSPSched.m decides
// whether "a process" is a coroutine on the scheduler or a plain thread.
//
// A waiter is used for exactly one wait. Whoever claims it -- a channel
// completing one of its entries, close, or its timeout -- calls
// CSPUnpark exactly once, so the waiter never needs to count wakeups.

#import <Foundation/Foundation.h>
#import <pthread.h>
#import <stdatomic.h>

// Takes a lock the library holds only briefly. A busy pthread mutex puts
// the caller to sleep in the kernel at once; these are held for well under
// a microsecond, so try for a moment first.
static inline void CSPLock(pthread_mutex_t *m) {
    for (int i = 0; i < 1000; i++) {
        if (pthread_mutex_trylock(m) == 0) return;
#if defined(__x86_64__)
        __asm__ volatile("pause");
#endif
    }
    pthread_mutex_lock(m);
}

typedef struct CSPProc CSPProc;

@interface CSPWaiter : NSObject {
@public
    _Atomic long fired;              // -1 until claimed; then which case
    CSPProc *proc;                   // the coroutine waiting, or NULL: a plain thread
    _Atomic int parkState;           // coroutines: 0 not yet parked, 1 parked, 2 woken
    dispatch_semaphore_t sem;        // plain threads
    long timerSlot;                  // coroutines: place in the timer heap, or -1
    long timerIndex;                 // the case a timeout claims
    const char *what;                // what it waits on, for the deadlock report
}
@end

// A waiter for the calling process; what is shown in deadlock reports.
CSPWaiter *CSPNewWaiter(const char *what);

// Waits until the waiter is claimed and unparked.
void CSPPark(CSPWaiter *w);

// Waits until claimed, or until seconds pass -- in which case the waiter
// is claimed for timeoutIndex, unless something else claimed it first.
// Either way, when this returns w->fired says which.
void CSPParkFor(CSPWaiter *w, long timeoutIndex, double seconds);

// Wakes a claimed waiter. Call exactly once, after claiming it.
void CSPUnpark(CSPWaiter *w);
