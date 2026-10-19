// test.m -- checks the library against words.txt, "To verify once built".

#import "CSP.h"
#import <stdatomic.h>

NSUInteger CSPChanQueued(Chan *c);

static int checks, failures;

#define CHECK(cond) do {                                                    \
    checks++;                                                               \
    if (!(cond)) {                                                          \
        failures++;                                                         \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
    }                                                                       \
} while (0)

static double now(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

static void pause_(double seconds) {
    [NSThread sleepForTimeInterval:seconds];
}

static BOOL raises(void (^block)(void)) {
    @try {
        block();
    } @catch (NSException *e) {
        return YES;
    }
    return NO;
}

static void section(const char *name) {
    printf("  %s\n", name);
}


// Processes used by the tests.

static void sendLater(Chan *c, id value, double seconds) {
    pause_(seconds);
    [c send:value];
}

static void closeLater(Chan *c, double seconds) {
    pause_(seconds);
    [c close];
}

static void doubler(Chan<NSNumber *> *jobs, Chan<NSNumber *> *out) {
    for (NSNumber *j in jobs) [out send:@(2 * j.intValue)];
    [out send:@(-1)];
}

static NSString *firstOrTimeout(Chan<NSString *> *c, double seconds) {
    alt {
        receive(s, c)   { return s; }
        after(seconds)  { return @"timeout"; }
    }
    return @"unreached";
}


static void testBuffered(void) {
    section("buffered: FIFO, capacity");
    Chan<NSNumber *> *c = chan(3);
    CHECK(c.capacity == 3);
    [c send:@1];
    [c send:@2];
    [c send:@3];
    CHECK([[c receive] isEqual:@1]);
    CHECK([[c receive] isEqual:@2]);
    CHECK([[c receive] isEqual:@3]);
    CHECK(chan().capacity == 0);
}

static atomic_int rendezvousSent;

static void sendThenMark(Chan *c) {
    [c send:@"x"];
    atomic_store(&rendezvousSent, 1);
}

static void testRendezvous(void) {
    section("unbuffered: send waits for the receiver");
    Chan<NSString *> *c = chan();
    go(sendThenMark(c));
    pause_(0.1);
    CHECK(atomic_load(&rendezvousSent) == 0);       // still waiting
    CHECK([[c receive] isEqualToString:@"x"]);
    for (int i = 0; i < 100 && !atomic_load(&rendezvousSent); i++) pause_(0.01);
    CHECK(atomic_load(&rendezvousSent) == 1);
}

static void testClose(void) {
    section("close: drain, then nil; errors");
    Chan<NSNumber *> *c = chan(5);
    [c send:@1];
    [c send:@2];
    [c close];
    CHECK([[c receive] isEqual:@1]);
    CHECK([[c receive] isEqual:@2]);
    CHECK([c receive] == nil);
    CHECK([c receive] == nil);

    CHECK(raises(^{ [c send:@3]; }));                // send after close
    CHECK(raises(^{ [c close]; }));                  // close twice
    id none = nil;
    CHECK(raises(^{ [chan() send:none]; }));         // nil

    // A receiver already waiting gets nil when the channel closes.
    Chan *d = chan();
    go(closeLater(d, 0.05));
    CHECK([d receive] == nil);
}

static void testRange(void) {
    section("for-in: work queue, each value exactly once");
    enum { N = 1000, WORKERS = 4 };
    Chan<NSNumber *> *jobs = chan(16);
    Chan<NSNumber *> *out = chan();
    for (int w = 0; w < WORKERS; w++) go(doubler(jobs, out));
    go({
        for (int i = 0; i < N; i++) [jobs send:@(i)];
        [jobs close];
    });
    static int seen[N];
    int finished = 0, count = 0, dup = 0;
    while (finished < WORKERS) {
        int v = [out receive].intValue;
        if (v < 0) { finished++; continue; }
        if (seen[v / 2]++) dup++;
        count++;
    }
    CHECK(count == N);
    CHECK(dup == 0);
}

static void testAltRandom(void) {
    section("alt: random choice among ready cases");
    Chan<NSNumber *> *a = chan(1), *b = chan(1);
    int fromA = 0, fromB = 0;
    for (int i = 0; i < 1000; i++) {
        [a send:@1];
        [b send:@2];
        alt {
            receive(x, a) { fromA++; }
            receive(y, b) { fromB++; }
        }
        alt { receive(x, a) { } otherwise { } }          // empty both again
        alt { receive(y, b) { } otherwise { } }
    }
    CHECK(fromA + fromB == 1000);
    CHECK(fromA > 400 && fromB > 400);
    printf("    a %d, b %d\n", fromA, fromB);
}

static void testOtherwise(void) {
    section("alt: otherwise only when nothing is ready");
    Chan<NSString *> *c = chan(1);
    __block NSString *got = nil;
    BOOL other = NO;
    alt {
        receive(s, c) { got = s; }
        otherwise     { other = YES; }
    }
    CHECK(other && got == nil);

    [c send:@"here"];
    other = NO;
    alt {
        receive(s, c) { got = s; }
        otherwise     { other = YES; }
    }
    CHECK(!other && [got isEqualToString:@"here"]);

    // A case on a nil channel is never ready.
    Chan<NSString *> *off = nil;
    other = NO;
    alt {
        receive(s, off) { got = s; }
        otherwise       { other = YES; }
    }
    CHECK(other);
}

static void testAfter(void) {
    section("alt: after's timing");
    Chan<NSString *> *c = chan();
    double t0 = now();
    CHECK([firstOrTimeout(c, 0.2) isEqualToString:@"timeout"]);
    double t = now() - t0;
    CHECK(t > 0.18 && t < 0.5);
    printf("    timed out after %.3f s (asked 0.200)\n", t);

    go(sendLater(c, @"early", 0.05));
    t0 = now();
    CHECK([firstOrTimeout(c, 2.0) isEqualToString:@"early"]);
    CHECK(now() - t0 < 1.0);
}

static void testSending(void) {
    section("alt: sending, deliver or stop, receive on closed");
    Chan<NSString *> *out = chan();
    Chan<NSString *> *got = chan(1);
    go({ [got send:[out receive]]; });
    BOOL delivered = NO;
    alt {
        sending(out, @"story") { delivered = YES; }
        after(2.0)             { }
    }
    CHECK(delivered);
    CHECK([[got receive] isEqualToString:@"story"]);

    // Nobody takes from out; quit closes, and the receive case fires with nil.
    Chan *quit = chan();
    go(closeLater(quit, 0.05));
    BOOL stopped = NO, sent = NO, nilOnClose = NO;
    alt {
        sending(out, @"unwanted") { sent = YES; }
        receive(q, quit)          { stopped = YES; nilOnClose = (q == nil); }
    }
    CHECK(stopped && !sent && nilOnClose);
    CHECK(CSPChanQueued(out) == 0);                  // the send case left nothing behind

    Chan *closed = chan();
    [closed close];
    CHECK(raises(^{ alt { sending(closed, @"x") { } } }));
}

static void testReturnAndTyping(void) {
    section("alt: return from a case; receive(x, c) is typed");
    Chan<NSString *> *c = chan(1);
    [c send:@"hello"];
    CHECK([firstOrTimeout(c, 1.0) isEqualToString:@"hello"]);

    [c send:@"typed"];
    NSUInteger length = 0;
    alt {
        receive(s, c) {
            _Static_assert(__builtin_types_compatible_p(__typeof__(s), NSString *),
                           "receive(x, c) types x from Chan<NSString *>");
            length = s.length;      // compiles only if s is an NSString *
        }
    }
    CHECK(length == 5);
}

static void testQueueCleanup(void) {
    section("alt: a case that never fires doesn't pile up");
    enum { N = 5000 };
    Chan<NSNumber *> *jobs = chan();
    Chan *done = chan();
    go({ for (int i = 0; i < N; i++) [jobs send:@(i)]; });
    int count = 0;
    BOOL stop = NO;
    while (!stop && count < N) {
        alt {
            receive(j, jobs) { count++; }
            receive(d, done) { stop = YES; }
        }
    }
    CHECK(count == N);
    CHECK(CSPChanQueued(done) == 0);
    CHECK(CSPChanQueued(jobs) == 0);
}

typedef struct { int day; double weight; } Sample;
typedef struct { short x, y; } Point_;
typedef struct { int day; double weight; } Anonymous;      // same fields as Sample
typedef struct Tagged { int day; double weight; } Tagged;

static void testParcel(void) {
    section("Parcel: round trip, wrong type, closed channel");
    Chan<Parcel *> *c = chan(2);
    Sample s = {3, 0.5};
    [c send:parcelFromStruct(s)];
    s.day = 99;                                      // the parcel holds a copy
    Sample got = structFromParcel(Sample, [c receive]);
    CHECK(got.day == 3 && got.weight == 0.5);

    [c send:parcelFromStruct(s)];
    CHECK(raises(^{ Point_ p = structFromParcel(Point_, [c receive]); (void)p; }));

    // Anonymous structs with the same fields can't be told apart; a tag can.
    CHECK(!raises(^{ Anonymous a = structFromParcel(Anonymous, parcelFromStruct(s)); (void)a; }));
    Tagged tg = {1, 2.0};
    CHECK(raises(^{ Sample t = structFromParcel(Sample, parcelFromStruct(tg)); (void)t; }));

    [c close];
    CHECK(raises(^{ Sample t = structFromParcel(Sample, [c receive]); (void)t; }));
}

static void testManyProcesses(void) {
    enum { N = 1900 };
    section("1,900 processes live at once");
    Chan *gate = chan();
    Chan<NSNumber *> *finished = chan(N);
    double t0 = now();
    for (int i = 0; i < N; i++) go({ [gate receive]; [finished send:@1]; });
    double started = now() - t0;
    [gate close];
    int n = 0;
    for (int i = 0; i < N; i++) n += [finished receive].intValue;
    CHECK(n == N);
    printf("    started in %.3f s, all done in %.3f s\n", started, now() - t0);
}

// Senders spread values across three unbuffered channels with alt;
// receivers take from all three with alt. Every value must arrive once.
static void stressSender(Chan<NSNumber *> *a, Chan<NSNumber *> *b, Chan<NSNumber *> *c,
                         int from, int count, Chan *done) {
    for (int i = from; i < from + count; i++) {
        NSNumber *v = @(i);
        alt {
            sending(a, v) { }
            sending(b, v) { }
            sending(c, v) { }
        }
    }
    [done send:@YES];
}

static void stressReceiver(Chan<NSNumber *> *a, Chan<NSNumber *> *b, Chan<NSNumber *> *c,
                           Chan *quit, Chan<NSArray<NSNumber *> *> *sums) {
    long long sum = 0, n = 0;
    for (;;) {
        BOOL stop = NO;
        alt {
            receive(x, a)    { sum += x.longLongValue; n++; }
            receive(x, b)    { sum += x.longLongValue; n++; }
            receive(x, c)    { sum += x.longLongValue; n++; }
            receive(q, quit) { stop = YES; }
        }
        if (stop) break;
    }
    [sums send:@[@(sum), @(n)]];         // one message, so reports can't interleave
}

// Each process offers to send and to receive on the same channel; any two
// pair up. Sends and receives must balance.
static void swapper(Chan<NSNumber *> *c, int rounds, Chan<NSArray<NSNumber *> *> *tally) {
    int sent = 0, got = 0;
    for (int i = 0; i < rounds; i++) {
        BOOL idle = NO;
        alt {
            sending(c, @1) { sent++; }
            receive(x, c)  { got++; }
            after(0.5)     { idle = YES; }
        }
        if (idle) break;
    }
    [tally send:@[@(sent), @(got)]];
}

static void testStress(void) {
    section("stress: many senders and receivers through alt");
    enum { SENDERS = 6, RECEIVERS = 5, EACH = 3000 };
    Chan<NSNumber *> *a = chan(), *b = chan(), *c = chan();
    Chan *done = chan(), *quit = chan();
    Chan<NSArray<NSNumber *> *> *sums = chan(RECEIVERS);
    for (int r = 0; r < RECEIVERS; r++) go(stressReceiver(a, b, c, quit, sums));
    for (int s = 0; s < SENDERS; s++) go(stressSender(a, b, c, s * EACH, EACH, done));
    for (int s = 0; s < SENDERS; s++) [done receive];
    [quit close];                    // every send has been received: they're unbuffered
    long long sum = 0, n = 0;
    for (int r = 0; r < RECEIVERS; r++) {
        NSArray<NSNumber *> *report = [sums receive];
        sum += report[0].longLongValue;
        n += report[1].longLongValue;
    }
    long long total = (long long)SENDERS * EACH;
    CHECK(n == total);
    CHECK(sum == total * (total - 1) / 2);

    section("stress: send and receive cases on the same channel");
    enum { SWAPPERS = 6, ROUNDS = 2000 };
    Chan<NSNumber *> *pair = chan();
    Chan<NSArray<NSNumber *> *> *tally = chan(SWAPPERS);
    for (int i = 0; i < SWAPPERS; i++) go(swapper(pair, ROUNDS, tally));
    int sent = 0, got = 0;
    for (int i = 0; i < SWAPPERS; i++) {
        NSArray<NSNumber *> *report = [tally receive];
        sent += report[0].intValue;
        got += report[1].intValue;
    }
    CHECK(sent == got);
    CHECK(sent > 0);
    printf("    %d pairings\n", sent);
}

int main(void) {
    @autoreleasepool {
        double t0 = now();
        printf("ObjCSP tests\n");
        testBuffered();
        testRendezvous();
        testClose();
        testRange();
        testAltRandom();
        testOtherwise();
        testAfter();
        testSending();
        testReturnAndTyping();
        testQueueCleanup();
        testParcel();
        testManyProcesses();
        testStress();
        printf("%d checks, %d failed, %.1f s\n", checks, failures, now() - t0);
        return failures ? 1 : 0;
    }
}
