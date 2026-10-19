// CSP.m -- the library behind CSP.h.
//
// The design follows Go's runtime. Each channel has a lock, a buffer, and
// two queues of waiting processes: receivers and senders. A process that
// can't proceed puts an entry on a queue and sleeps on its own semaphore.
// Whoever completes it -- a sender, a receiver, or close -- claims the
// entry, hands over the value, and signals the semaphore.
//
// alt puts one entry per case on several channels at once, all sharing
// one waiter. The first channel to claim the waiter wins; the claim is an
// atomic compare-and-swap, so the losers see it taken and skip it. When
// alt wakes it takes its remaining entries off every queue.
//
// alt locks all its channels at once, always in address order, and
// everything else locks one channel at a time, so locks can't deadlock.

#import "CSP.h"
#import <pthread.h>
#import <stdatomic.h>

// The runtime calls @autoreleasepool { } compiles to; for-in needs a pool
// that opens in one call and closes in the next.
void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *pool);

// A process waiting on one or more channel operations.
@interface CSPWaiter : NSObject {
@public
    _Atomic long fired;              // -1 until one of its entries is claimed
    dispatch_semaphore_t sem;
}
@end

@implementation CSPWaiter
- (instancetype)init {
    if ((self = [super init])) {
        atomic_init(&fired, -1);
        sem = dispatch_semaphore_create(0);
    }
    return self;
}
@end

typedef enum { CSPReceive, CSPSend, CSPAfter, CSPOtherwise } CSPKind;

// One operation: a plain send or receive, or one case of an alt. While
// its process waits, the entry sits on its channel's queue.
@interface CSPEntry : NSObject {
@public
    CSPWaiter *waiter;
    long index;                      // which case of the waiter
    CSPKind kind;
    Chan *chan;
    id value;                        // the value to send, or the one received
    BOOL closed;                     // completed by close rather than a value
}
@end

@implementation CSPEntry
@end

static CSPEntry *entry(CSPWaiter *w, long index, CSPKind kind, Chan *c, id value) {
    CSPEntry *e = [CSPEntry new];
    e->waiter = w;
    e->index = index;
    e->kind = kind;
    e->chan = c;
    e->value = value;
    return e;
}

// Claims e for its waiter. Fails if another of the waiter's entries was
// claimed first.
static BOOL claim(CSPEntry *e) {
    long none = -1;
    return atomic_compare_exchange_strong(&e->waiter->fired, &none, e->index);
}

static void wake(CSPEntry *_Nullable e) {
    if (e) dispatch_semaphore_signal(e->waiter->sem);
}

// Takes the first entry on q that can still be claimed, dropping the ones
// whose alt already went another way.
static CSPEntry *dequeue(NSMutableArray<CSPEntry *> *q) {
    while (q.count) {
        CSPEntry *e = q[0];
        [q removeObjectAtIndex:0];
        if (claim(e)) return e;
    }
    return nil;
}

static void sleepForever(void) {
    dispatch_semaphore_wait(dispatch_semaphore_create(0), DISPATCH_TIME_FOREVER);
}


@implementation Chan {
@public
    pthread_mutex_t mu;
    NSUInteger cap;
    BOOL closed;
    NSMutableArray *buf;
    NSMutableArray<CSPEntry *> *recvq;
    NSMutableArray<CSPEntry *> *sendq;
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        pthread_mutex_init(&mu, NULL);
        cap = capacity;
        buf = [NSMutableArray arrayWithCapacity:MIN(capacity, (NSUInteger)1024)];
        recvq = [NSMutableArray new];
        sendq = [NSMutableArray new];
    }
    return self;
}

- (instancetype)init {
    return [self initWithCapacity:0];
}

- (void)dealloc {
    pthread_mutex_destroy(&mu);
}

- (NSUInteger)capacity {
    return cap;
}

// The two operations that don't have to wait, shared by send, receive and
// alt. Called with the lock held; if they complete another process's
// entry, it comes back in *woken, to be signalled once the lock is dropped.
//
// The out-parameters are __strong on purpose. ARC's default for them is
// __autoreleasing, which would put every value received, and every entry
// woken, into the calling thread's autorelease pool -- held until the
// process ends, out of reach of any pool in the client's loop body.

static BOOL tryReceive(Chan *c, id _Nullable __strong *out, CSPEntry *_Nullable __strong *woken) {
    if (c->buf.count) {
        *out = c->buf[0];
        [c->buf removeObjectAtIndex:0];
        CSPEntry *s = dequeue(c->sendq);        // room now for a waiting sender
        if (s) {
            [c->buf addObject:s->value];
            *woken = s;
        }
        return YES;
    }
    CSPEntry *s = dequeue(c->sendq);
    if (s) {
        *out = s->value;
        *woken = s;
        return YES;
    }
    if (c->closed) {
        *out = nil;
        return YES;
    }
    return NO;
}

static BOOL trySend(Chan *c, id value, CSPEntry *_Nullable __strong *woken) {
    CSPEntry *r = dequeue(c->recvq);
    if (r) {
        r->value = value;
        *woken = r;
        return YES;
    }
    if (c->buf.count < c->cap) {
        [c->buf addObject:value];
        return YES;
    }
    return NO;
}

static void raiseClosed(NSString *what) {
    [NSException raise:NSInternalInconsistencyException format:@"%@ on a closed channel", what];
}

- (void)send:(id)value {
    if (!value) [NSException raise:NSInvalidArgumentException format:@"send: nil can't be sent"];
    pthread_mutex_lock(&mu);
    if (closed) {
        pthread_mutex_unlock(&mu);
        raiseClosed(@"send:");
    }
    CSPEntry *woken = nil;
    if (trySend(self, value, &woken)) {
        pthread_mutex_unlock(&mu);
        wake(woken);
        return;
    }
    CSPWaiter *w = [CSPWaiter new];
    CSPEntry *e = entry(w, 0, CSPSend, self, value);
    [sendq addObject:e];
    pthread_mutex_unlock(&mu);
    dispatch_semaphore_wait(w->sem, DISPATCH_TIME_FOREVER);
    if (e->closed) raiseClosed(@"send:");
}

- (id)receive {
    pthread_mutex_lock(&mu);
    id value = nil;
    CSPEntry *woken = nil;
    if (tryReceive(self, &value, &woken)) {
        pthread_mutex_unlock(&mu);
        wake(woken);
        return value;
    }
    CSPWaiter *w = [CSPWaiter new];
    CSPEntry *e = entry(w, 0, CSPReceive, self, nil);
    [recvq addObject:e];
    pthread_mutex_unlock(&mu);
    dispatch_semaphore_wait(w->sem, DISPATCH_TIME_FOREVER);
    return e->value;
}

- (void)close {
    pthread_mutex_lock(&mu);
    if (closed) {
        pthread_mutex_unlock(&mu);
        [NSException raise:NSInternalInconsistencyException format:@"close: channel already closed"];
    }
    closed = YES;
    // Every waiting receiver gets nil, every waiting sender an error.
    // Values already in the buffer stay there to be received.
    NSMutableArray<CSPEntry *> *woken = [NSMutableArray new];
    for (NSMutableArray<CSPEntry *> *q in @[recvq, sendq]) {
        for (CSPEntry *e in q) {
            if (claim(e)) {
                e->closed = YES;
                if (e->kind == CSPReceive) e->value = nil;
                [woken addObject:e];
            }
        }
        [q removeAllObjects];
    }
    pthread_mutex_unlock(&mu);
    for (CSPEntry *e in woken) wake(e);
}

// for (x in c): one value per call. Each pass of the loop runs in its own
// autorelease pool, pushed here before the body and popped on the next
// call, so whatever the body autoreleases is freed every pass and a
// long-running loop doesn't grow. The value itself is autoreleased into
// that pool, which keeps it alive while the body uses it. A loop left by
// break leaves its pool open; the enclosing pool drains it, value and all.
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len {
    if (state->extra[0]) {
        objc_autoreleasePoolPop((void *)state->extra[0]);
        state->extra[0] = 0;
    }
    id value = [self receive];
    if (!value) return 0;
    state->extra[0] = (unsigned long)objc_autoreleasePoolPush();
    CFAutorelease(CFBridgingRetain(value));
    buffer[0] = value;
    state->itemsPtr = buffer;
    state->mutationsPtr = &state->extra[1];
    state->state = 1;
    return 1;
}

@end

// For tests: how many entries are queued on c, stale ones included.
NSUInteger CSPChanQueued(Chan *c) {
    pthread_mutex_lock(&c->mu);
    NSUInteger n = c->recvq.count + c->sendq.count;
    pthread_mutex_unlock(&c->mu);
    return n;
}

Chan *CSPMakeChan(NSUInteger capacity) {
    return [[Chan alloc] initWithCapacity:capacity];
}


// go

static void *runProcess(void *arg) {
    @autoreleasepool {
        void (^block)(void) = (__bridge_transfer id)arg;
        block();
    }
    return NULL;
}

void CSPGo(void (^block)(void)) {
    // Foundation assumes it is single-threaded until an NSThread has been
    // started; start one so it locks properly around our raw threads.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSThread detachNewThreadWithBlock:^{}];
    });

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    void *arg = (__bridge_retained void *)[block copy];
    pthread_t thread;
    int err = pthread_create(&thread, &attr, runProcess, arg);
    pthread_attr_destroy(&attr);
    if (err) {
        CFRelease(arg);
        [NSException raise:NSInternalInconsistencyException
                    format:@"go: can't start a process: %s (macOS allows 2,048 threads per program)",
                           strerror(err)];
    }
}


// alt

@interface CSPAlt : NSObject {
@public
    int pass;                        // 0 new, 1 registering, 2 running the chosen case, 3 done
    long next;                       // case counter, reset each pass
    NSMutableArray<CSPEntry *> *cases;
    long chosen;
    BOOL ran;
    id received;
    long afterIndex;
    double afterSeconds;
    long otherwiseIndex;
}
- (void)choose;
@end

CSPAlt *CSPAltBegin(void) {
    CSPAlt *a = [CSPAlt new];
    a->cases = [NSMutableArray new];
    a->chosen = -1;
    a->afterIndex = -1;
    a->otherwiseIndex = -1;
    return a;
}

BOOL CSPAltNext(CSPAlt *a) {
    switch (a->pass) {
    case 0:
        a->pass = 1;
        a->next = 0;
        return YES;
    case 1:
        [a choose];
        a->pass = 2;
        a->next = 0;
        return YES;
    default:
        a->pass = 3;
        return NO;
    }
}

int CSPAltPass(CSPAlt *a) {
    return a->pass;
}

long CSPAltIndex(CSPAlt *a) {
    return a->next++;
}

static void addCase(CSPAlt *a, long i, CSPKind kind, Chan *c, id value) {
    NSCAssert(i == (long)a->cases.count, @"alt: cases out of order");
    [a->cases addObject:entry(nil, i, kind, c, value)];
}

BOOL CSPAltAddReceive(CSPAlt *a, long i, Chan *c) {
    addCase(a, i, CSPReceive, c, nil);
    return NO;
}

BOOL CSPAltAddSend(CSPAlt *a, long i, Chan *c, id value) {
    if (!value) [NSException raise:NSInvalidArgumentException format:@"sending: nil can't be sent"];
    addCase(a, i, CSPSend, c, value);
    return NO;
}

BOOL CSPAltAddAfter(CSPAlt *a, long i, double seconds) {
    addCase(a, i, CSPAfter, nil, nil);
    if (a->afterIndex < 0 || seconds < a->afterSeconds) {
        a->afterIndex = i;
        a->afterSeconds = seconds;
    }
    return NO;
}

BOOL CSPAltAddOtherwise(CSPAlt *a, long i) {
    if (a->otherwiseIndex >= 0) [NSException raise:NSInvalidArgumentException format:@"alt: two otherwise cases"];
    addCase(a, i, CSPOtherwise, nil, nil);
    a->otherwiseIndex = i;
    return NO;
}

BOOL CSPAltFire(CSPAlt *a, long i) {
    if (i == a->chosen && !a->ran) {
        a->ran = YES;
        return YES;
    }
    return NO;
}

id CSPAltValue(CSPAlt *a) {
    return a->received;
}

@implementation CSPAlt

// The channels in the cases, each once, in address order.
- (NSArray<Chan *> *)lockOrder {
    NSMutableArray<Chan *> *chans = [NSMutableArray new];
    for (CSPEntry *e in cases)
        if (e->chan && [chans indexOfObjectIdenticalTo:e->chan] == NSNotFound)
            [chans addObject:e->chan];
    [chans sortUsingComparator:^NSComparisonResult(Chan *x, Chan *y) {
        uintptr_t px = (uintptr_t)(__bridge void *)x, py = (uintptr_t)(__bridge void *)y;
        return px < py ? NSOrderedAscending : px > py ? NSOrderedDescending : NSOrderedSame;
    }];
    return chans;
}

static void lockAll(NSArray<Chan *> *chans) {
    for (Chan *c in chans) pthread_mutex_lock(&c->mu);
}

static void unlockAll(NSArray<Chan *> *chans) {
    for (Chan *c in chans.reverseObjectEnumerator) pthread_mutex_unlock(&c->mu);
}

// Picks a ready case, waiting if none is, and does it. Sets chosen, and
// received for a receive case.
- (void)choose {
    NSArray<Chan *> *chans = [self lockOrder];

    // Channel cases in random order, so that when several are ready each
    // is equally likely. A nil channel is never ready, as in Go.
    NSMutableArray<CSPEntry *> *order = [NSMutableArray new];
    for (CSPEntry *e in cases)
        if (e->chan) [order addObject:e];
    for (NSUInteger k = order.count; k > 1; k--)
        [order exchangeObjectAtIndex:k - 1 withObjectAtIndex:arc4random_uniform((uint32_t)k)];

    lockAll(chans);

    for (CSPEntry *e in order) {
        CSPEntry *woken = nil;
        BOOL done;
        id value = nil;
        if (e->kind == CSPReceive) {
            done = tryReceive(e->chan, &value, &woken);
        } else {
            if (e->chan->closed) {
                unlockAll(chans);
                raiseClosed(@"sending");
            }
            done = trySend(e->chan, e->value, &woken);
        }
        if (done) {
            unlockAll(chans);
            wake(woken);
            chosen = e->index;
            received = value;
            return;
        }
    }

    if (otherwiseIndex >= 0) {
        unlockAll(chans);
        chosen = otherwiseIndex;
        return;
    }

    if (order.count == 0 && afterIndex < 0) {     // alt {} waits forever, as in Go
        unlockAll(chans);
        sleepForever();
    }

    // Nothing ready: queue on every channel, and wait.
    CSPWaiter *w = [CSPWaiter new];
    for (CSPEntry *e in order) {
        e->waiter = w;
        [e->kind == CSPReceive ? e->chan->recvq : e->chan->sendq addObject:e];
    }
    unlockAll(chans);

    if (afterIndex >= 0) {
        dispatch_time_t t = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(afterSeconds, 0) * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(w->sem, t) != 0) {
            // Timed out -- unless a channel claimed us in the meantime, in
            // which case its signal is on the way.
            long none = -1;
            if (!atomic_compare_exchange_strong(&w->fired, &none, afterIndex))
                dispatch_semaphore_wait(w->sem, DISPATCH_TIME_FOREVER);
        }
    } else {
        dispatch_semaphore_wait(w->sem, DISPATCH_TIME_FOREVER);
    }
    chosen = atomic_load(&w->fired);

    // Off every queue, so a case that never fires doesn't pile up entries.
    lockAll(chans);
    for (CSPEntry *e in order)
        [e->kind == CSPReceive ? e->chan->recvq : e->chan->sendq removeObjectIdenticalTo:e];
    unlockAll(chans);

    CSPEntry *e = cases[chosen];
    if (e->kind == CSPSend && e->closed) raiseClosed(@"sending");
    if (e->kind == CSPReceive) received = e->value;
}

@end


// Parcel

@implementation Parcel {
    NSData *bytes;
    NSString *type;
}

- (instancetype)initWithBytes:(const void *)b size:(size_t)size type:(const char *)t {
    if (strchr(t, '@') || strchr(t, '#'))
        [NSException raise:NSInvalidArgumentException
                    format:@"parcelFromStruct: struct %s holds objects; use a small class instead", t];
    if ((self = [super init])) {
        bytes = [NSData dataWithBytes:b length:size];
        type = @(t);
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<Parcel %@, %lu bytes>", type, (unsigned long)bytes.length];
}

void CSPStructFromParcel(Parcel *p, void *dst, size_t size, const char *t) {
    if (!p)
        [NSException raise:NSInvalidArgumentException format:@"structFromParcel: no parcel (closed channel?)"];
    if (![p->type isEqualToString:@(t)] || p->bytes.length != size)
        [NSException raise:NSInvalidArgumentException
                    format:@"structFromParcel: asked for %s, parcel holds %@", t, p->type];
    memcpy(dst, p->bytes.bytes, size);
}

@end
