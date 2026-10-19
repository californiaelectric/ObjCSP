// objects.m -- many objects, each handled by its own process: set a
// value, then call a method that computes from it.
//
//     ./objects [-linear] [n [work]]
//
// n objects (default 10,000); work is how many steps each one's compute
// method takes (default 10,000 -- about 10 us). -linear does the same in
// plain loops on main.
//
// 1. Each process makes an object, sets its value, computes, and sends it
//    to main; main confirms every value arrived exactly once.
// 2. main makes the objects; each process sets the value on the one it
//    was given and computes; main reads them all back. A channel passes
//    a reference, so the process changes the same object main holds.
//
// Both print a checksum of every result, the same in either mode.

#import <Foundation/Foundation.h>
#import <time.h>
#import "../CSP.h"

@interface Thing : NSObject
@property int value;
@property uint64_t result;
- (void)compute:(int)steps;
@end

@implementation Thing

// xorshift from the value: each step depends on the one before, so the
// work can't be skipped.
- (void)compute:(int)steps {
    uint64_t x = (uint64_t)self.value + 1;
    for (int s = 0; s < steps; s++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
    }
    self.result = x;
}

@end

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

// 1: make one, set it, compute, send it.
void make(int i, int work, Chan<Thing *> *out) {
    Thing *t = [Thing new];
    t.value = i;
    [t compute:work];
    [out send:t];
}

// 2: set the one we were given, compute, then say done.
void set(Thing *t, int i, int work, Chan<NSNull *> *done) {
    t.value = i;
    [t compute:work];
    [done send:[NSNull null]];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int a = 1;
        BOOL linear = argc > a && !strcmp(argv[a], "-linear");
        if (linear) a++;
        int n = argc > a ? atoi(argv[a]) : 10000;
        int work = argc > a + 1 ? atoi(argv[a + 1]) : 10000;
        const char *how = linear ? "in a loop" : "by processes";

        // 1
        double t0 = now();
        char *seen = calloc(n, 1);
        int wrong = 0;
        uint64_t sum = 0;
        if (linear) {
            for (int i = 0; i < n; i++) {
                Thing *t = [Thing new];
                t.value = i;
                [t compute:work];
                if (t.value < 0 || t.value >= n || seen[t.value]++) wrong++;
                sum ^= t.result;
            }
        } else {
            Chan<Thing *> *out = chan();
            for (int i = 0; i < n; i++)
                go(make(i, work, out));
            for (int i = 0; i < n; i++) {
                Thing *t = [out receive];
                if (t.value < 0 || t.value >= n || seen[t.value]++) wrong++;
                sum ^= t.result;
            }
        }
        free(seen);
        printf("made %-13s %d objects, %d wrong, checksum %016llx, %.4f s\n", how, n, wrong, sum, now() - t0);

        // 2
        t0 = now();
        NSMutableArray<Thing *> *things = [NSMutableArray arrayWithCapacity:n];
        for (int i = 0; i < n; i++) [things addObject:[Thing new]];
        if (linear) {
            for (int i = 0; i < n; i++) {
                things[i].value = i;
                [things[i] compute:work];
            }
        } else {
            Chan<NSNull *> *done = chan();
            for (int i = 0; i < n; i++)
                go(set(things[i], i, work, done));
            for (int i = 0; i < n; i++) [done receive];
        }
        wrong = 0;
        sum = 0;
        for (int i = 0; i < n; i++) {
            if (things[i].value != i) wrong++;
            sum ^= things[i].result;
        }
        printf("changed %-10s %d objects, %d wrong, checksum %016llx, %.4f s\n", how, n, wrong, sum, now() - t0);
    }
    return 0;
}
