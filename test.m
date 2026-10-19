// test.m -- checks the library against words.txt, "To verify once built".

#import <fcntl.h>
#import <libproc.h>
#import <mach-o/dyld.h>
#import <spawn.h>
#import <stdatomic.h>
#import <sys/resource.h>
#import <sys/wait.h>
#import "CSP.h"

NSUInteger CSPChanQueued(Chan *c);
const char *CSPMode(void);
long CSPMaxProcs(void);

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
    ALT {
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

static void testRangePools(void) {
    section("for-in: each pass drains its own pool; break frees the last value");
    Chan<NSNumber *> *c = chan(3);
    [c send:@1];
    [c send:@2];
    [c send:@3];
    [c close];
    __weak id previous = nil;
    int pass = 0, survived = 0;
    @autoreleasepool {
        for (NSNumber *n in c) {
            (void)n;
            if (pass++ > 0 && previous != nil) survived++;
            NSObject *o = [NSObject new];
            previous = o;
            CFAutorelease(CFBridgingRetain(o));      // held only by this pass's pool
        }
    }
    CHECK(pass == 3);
    CHECK(survived == 0);

    Chan *d = chan(1);
    __weak id last = nil;
    @autoreleasepool {
        [d send:[NSObject new]];                     // held only by the channel
        for (id x in d) {
            last = x;
            break;
        }
    }
    CHECK(last == nil);
}

static void testAltRandom(void) {
    section("ALT: random choice among ready cases");
    Chan<NSNumber *> *a = chan(1), *b = chan(1);
    int fromA = 0, fromB = 0;
    for (int i = 0; i < 1000; i++) {
        [a send:@1];
        [b send:@2];
        ALT {
            receive(x, a) { fromA++; }
            receive(y, b) { fromB++; }
        }
        ALT { receive(x, a) { } OTHERWISE { } }          // empty both again
        ALT { receive(y, b) { } OTHERWISE { } }
    }
    CHECK(fromA + fromB == 1000);
    CHECK(fromA > 400 && fromB > 400);
    printf("    a %d, b %d\n", fromA, fromB);
}

static void testOtherwise(void) {
    section("ALT: OTHERWISE only when nothing is ready");
    Chan<NSString *> *c = chan(1);
    __block NSString *got = nil;
    BOOL other = NO;
    ALT {
        receive(s, c) { got = s; }
        OTHERWISE     { other = YES; }
    }
    CHECK(other && got == nil);

    [c send:@"here"];
    other = NO;
    ALT {
        receive(s, c) { got = s; }
        OTHERWISE     { other = YES; }
    }
    CHECK(!other && [got isEqualToString:@"here"]);

    // A case on a nil channel is never ready.
    Chan<NSString *> *off = nil;
    other = NO;
    ALT {
        receive(s, off) { got = s; }
        OTHERWISE       { other = YES; }
    }
    CHECK(other);
}

static void testAfter(void) {
    section("ALT: after's timing");
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
    section("ALT: sending, deliver or stop, receive on closed");
    Chan<NSString *> *out = chan();
    Chan<NSString *> *got = chan(1);
    go({ [got send:[out receive]]; });
    BOOL delivered = NO;
    ALT {
        sending(out, @"story") { delivered = YES; }
        after(2.0)             { }
    }
    CHECK(delivered);
    CHECK([[got receive] isEqualToString:@"story"]);

    // Nobody takes from out; quit closes, and the receive case fires with nil.
    Chan *quit = chan();
    go(closeLater(quit, 0.05));
    BOOL stopped = NO, sent = NO, nilOnClose = NO;
    ALT {
        sending(out, @"unwanted") { sent = YES; }
        receive(q, quit)          { stopped = YES; nilOnClose = (q == nil); }
    }
    CHECK(stopped && !sent && nilOnClose);
    CHECK(CSPChanQueued(out) == 0);                  // the send case left nothing behind

    Chan *closed = chan();
    [closed close];
    CHECK(raises(^{ ALT { sending(closed, @"x") { } } }));
}

static void testReturnAndTyping(void) {
    section("ALT: return from a case; receive(x, c) is typed");
    Chan<NSString *> *c = chan(1);
    [c send:@"hello"];
    CHECK([firstOrTimeout(c, 1.0) isEqualToString:@"hello"]);

    [c send:@"typed"];
    NSUInteger length = 0;
    ALT {
        receive(s, c) {
            _Static_assert(__builtin_types_compatible_p(__typeof__(s), NSString *),
                           "receive(x, c) types x from Chan<NSString *>");
            length = s.length;      // compiles only if s is an NSString *
        }
    }
    CHECK(length == 5);
}

static void testQueueCleanup(void) {
    section("ALT: a case that never fires doesn't pile up");
    enum { N = 5000 };
    Chan<NSNumber *> *jobs = chan();
    Chan *done = chan();
    go({ for (int i = 0; i < N; i++) [jobs send:@(i)]; });
    int count = 0;
    BOOL stop = NO;
    while (!stop && count < N) {
        ALT {
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

// Pools that span several pages, closed after the process has moved
// between workers: closing frees pages that another worker created.
static void poolMover(int rounds, Chan *done) {
    for (int r = 0; r < rounds; r++) {
        @autoreleasepool {
            for (int i = 0; i < 2000; i++) CFAutorelease(CFBridgingRetain([NSObject new]));
            yield();
            @autoreleasepool {
                for (int i = 0; i < 2000; i++) CFAutorelease(CFBridgingRetain([NSObject new]));
                yield();
            }
            yield();
        }
        yield();
    }
    [done send:@YES];
}

static void testPoolsMoveWithProcesses(void) {
    section("pools spanning pages, opened and closed on different workers");
    enum { PROCS = 32, ROUNDS = 20 };
    Chan *done = chan(PROCS);
    for (int i = 0; i < PROCS; i++) go(poolMover(ROUNDS, done));
    for (int i = 0; i < PROCS; i++) [done receive];
    CHECK(YES);
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

// Senders spread values across three unbuffered channels with ALT;
// receivers take from all three with ALT. Every value must arrive once.
static void stressSender(Chan<NSNumber *> *a, Chan<NSNumber *> *b, Chan<NSNumber *> *c,
                         int from, int count, Chan *done) {
    for (int i = from; i < from + count; i++) {
        NSNumber *v = @(i);
        ALT {
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
        ALT {
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
        ALT {
            sending(c, @1) { sent++; }
            receive(x, c)  { got++; }
            after(0.5)     { idle = YES; }
        }
        if (idle) break;
    }
    [tally send:@[@(sent), @(got)]];
}

static void testStress(void) {
    section("stress: many senders and receivers through ALT");
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


// The scheduler's own features.

static BOOL scheduler(void) {
    return !strcmp(CSPMode(), "scheduler");
}

static void sleepThenReport(double seconds, Chan<NSNumber *> *out) {
    double t0 = now();
    sleepFor(seconds);
    [out send:@(now() - t0)];
}

static void testSleepFor(void) {
    section("sleepFor: pauses only the process");
    double t0 = now();
    sleepFor(0.1);                                   // from main, a plain thread
    double t = now() - t0;
    CHECK(t > 0.09 && t < 0.4);

    // 200 processes each sleep 0.2 s at once: about 0.2 s in all, not 40 s.
    enum { N = 200 };
    Chan<NSNumber *> *out = chan(N);
    t0 = now();
    for (int i = 0; i < N; i++) go(sleepThenReport(0.2, out));
    double shortest = 1e9;
    for (int i = 0; i < N; i++) {
        double slept = [out receive].doubleValue;    // not inside MIN(): it may evaluate twice
        if (slept < shortest) shortest = slept;
    }
    t = now() - t0;
    CHECK(shortest > 0.18);
    CHECK(t < 1.0);
    printf("    200 processes slept 0.2 s each: %.3f s in all\n", t);
}

static atomic_int yieldFlag;

static void spinner(Chan<NSNumber *> *out) {
    // Computes until another process sets the flag. With one worker it can
    // only ever see it set if yield lets the other one run.
    double t0 = now();
    long spins = 0;
    while (!atomic_load(&yieldFlag) && now() - t0 < 3.0) {
        spins++;
        yield();
    }
    [out send:@(atomic_load(&yieldFlag))];
}

static void testYield(void) {
    section("yield: a computing process lets others run");
    atomic_store(&yieldFlag, 0);
    Chan<NSNumber *> *out = chan(1);
    go(spinner(out));
    go({ atomic_store(&yieldFlag, 1); });
    CHECK([out receive].boolValue);
}

static void blockedReader(int fd, Chan<NSNumber *> *out) {
    char c = 0;
    ssize_t n = read(fd, &c, 1);                     // blocks its whole worker
    [out send:@(n == 1 && c == 'x')];
}

static void testMonitor(void) {
    section("monitor: a process blocked in the kernel doesn't stop the others");
    // One process blocks in read() on a pipe; only another process can
    // write to it. With one worker, that needs the monitor's stand-in.
    int fds[2];
    pipe(fds);
    int readEnd = fds[0], writeEnd = fds[1];         // go() can't capture a C array
    Chan<NSNumber *> *out = chan(1);
    go(blockedReader(readEnd, out));
    sleepFor(0.05);                                  // let the reader block first
    go({ write(writeEnd, "x", 1); });
    NSNumber *got = nil;
    ALT {
        receive(r, out) { got = r; }
        after(3.0)      { }
    }
    CHECK(got.boolValue);
    close(fds[0]);
    close(fds[1]);
}

static void testTimersInProcesses(void) {
    section("after inside processes");
    enum { N = 100 };
    Chan<NSString *> *never = chan();
    Chan<NSString *> *results = chan(N);
    double t0 = now();
    for (int i = 0; i < N; i++) go({ [results send:firstOrTimeout(never, 0.1 + 0.001 * i)]; });
    int timeouts = 0;
    for (int i = 0; i < N; i++) timeouts += [[results receive] isEqualToString:@"timeout"];
    CHECK(timeouts == N);
    CHECK(now() - t0 < 1.0);
}

static void testManyMore(void) {
    if (!scheduler()) return;                        // past the thread limit
#if defined(__has_feature) && __has_feature(thread_sanitizer)
    enum { N = 5000 };                               // the race checker tracks at most 8,128
    section("5,000 processes live at once (20,000 without the race checker)");
#else
    enum { N = 20000 };
    section("20,000 processes live at once");
#endif
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

static void testIdleWakeups(void) {
    if (!scheduler()) return;
    section("idle: processes all waiting, no wake-ups");
    Chan *never = chan();
    for (int i = 0; i < 100; i++) go({ [never receive]; });
    sleepFor(0.2);                                   // let workers finish spinning and sleep
    struct rusage_info_v4 a, b;
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&a);
    sleepFor(1.0);
    proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&b);
    uint64_t wakeups = (b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups) + (b.ri_interrupt_wkups - a.ri_interrupt_wkups);
    CHECK(wakeups < 20);
    printf("    %llu wake-ups in 1 s\n", wakeups);
}

// The checks that end their program run in a copy of this one.
static int runChild(const char *mode, double quitAfter, NSString **errors) {
    int err[2];
    pipe(err);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, err[1], 2);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    char self[1024];
    uint32_t size = sizeof self;
    _NSGetExecutablePath(self, &size);
    char *argv[] = {self, (char *)mode, NULL};
    extern char **environ;
    pid_t pid;
    posix_spawn(&pid, self, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(err[1]);
    if (quitAfter > 0) {
        pause_(quitAfter);
        kill(pid, SIGQUIT);
    }
    NSMutableData *data = [NSMutableData new];
    char buf[4096];
    ssize_t n;
    while ((n = read(err[0], buf, sizeof buf)) > 0) [data appendBytes:buf length:n];
    close(err[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    *errors = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return status;
}

static void testEndings(void) {
    if (!scheduler()) return;
    NSString *e = nil;
    int status;

    section("deadlock: reported, exit 2");
    status = runChild("--deadlock", 0, &e);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 2);
    CHECK([e containsString:@"all processes are asleep -- deadlock!"]);
    CHECK([e containsString:@"main [waiting in receive]"]);
    CHECK([e containsString:@"[waiting in receive], started at test.m"]);

    section("stack overflow: a clear message");
    status = runChild("--overflow", 0, &e);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    CHECK([e containsString:@"process stack overflow (1 MB)"]);
    CHECK([e containsString:@"recurse(1)"]);

    section("@catch: a channel operation inside one is stopped");
    status = runChild("--catch", 0, &e);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    CHECK([e containsString:@"inside @catch or @finally"]);

    section("ctrl-\\: dumps every process, exit 2");
    status = runChild("--waitforquit", 0.5, &e);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 2);
    CHECK([e containsString:@"SIGQUIT"]);
    CHECK([e containsString:@"[waiting in receive], started at test.m"]);
}

static volatile int depth;

#pragma clang diagnostic ignored "-Winfinite-recursion"
static int recurse(int n) {
    volatile char frame[4096];
    frame[0] = (char)n;
    depth = n;
    return recurse(n + 1) + frame[0];
}

// The children for testEndings.
static int child(const char *mode) {
    if (!strcmp(mode, "--deadlock")) {
        Chan *a = chan(), *b = chan();
        go([a receive]);
        [b receive];
    } else if (!strcmp(mode, "--overflow")) {
        go(recurse(1));
        sleepFor(10);
    } else if (!strcmp(mode, "--catch")) {
        Chan *c = chan();
        go({
            @try {
                [NSException raise:@"test" format:@"test"];
            } @catch (NSException *x) {
                [c receive];
            }
        });
        sleepFor(10);
    } else if (!strcmp(mode, "--waitforquit")) {
        Chan *a = chan();
        go([a receive]);
        sleepFor(10);
    }
    return 3;                                        // none of them should get here
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);             // so a fatal report shows how far it got
        if (argc > 1) return child(argv[1]);
        double t0 = now();
        if (scheduler())
            printf("ObjCSP tests -- scheduler, %ld worker%s\n", CSPMaxProcs(), CSPMaxProcs() == 1 ? "" : "s");
        else
            printf("ObjCSP tests -- threads, one per process\n");
        testBuffered();
        testRendezvous();
        testClose();
        testRange();
        testRangePools();
        testAltRandom();
        testOtherwise();
        testAfter();
        testSending();
        testReturnAndTyping();
        testQueueCleanup();
        testParcel();
        testPoolsMoveWithProcesses();
        testManyProcesses();
        testStress();
        testSleepFor();
        testYield();
        testMonitor();
        testTimersInProcesses();
        testManyMore();
        testIdleWakeups();
        testEndings();
        printf("%d checks, %d failed, %.1f s\n", checks, failures, now() - t0);
        return failures ? 1 : 0;
    }
}
