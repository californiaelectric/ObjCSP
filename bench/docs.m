// docs.m -- the "sorting documents" benchmark, ObjCSP version, line for
// line with docs.go. See there for what it does.
//
//     ./docs-objcsp [-linear] [trials [outfile]]

#import <Foundation/Foundation.h>
#import <time.h>
#import "../CSP.h"

enum { D = 2000 };

static NSArray<NSSet<NSString *> *> *loadCategories(NSString *path) {
    NSString *data = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!data) {
        fprintf(stderr, "docs: run make data first\n");
        exit(1);
    }
    NSMutableArray *cs = [NSMutableArray new];
    NSString *trimmed = [data stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *line in [trimmed componentsSeparatedByString:@"\n"])
        [cs addObject:[NSSet setWithArray:[line componentsSeparatedByString:@" "]]];
    return cs;
}

static NSString *docPath(NSString *dir, int d) {
    return [NSString stringWithFormat:@"%@/doc%04d.txt", dir, d];
}

static NSArray<NSString *> *readWords(NSString *path) {
    NSString *data = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    return [data componentsSeparatedByString:@" "];
}

static int count(NSArray<NSString *> *words, NSSet<NSString *> *c) {
    int n = 0;
    for (NSString *w in words)
        if ([c containsObject:w]) n++;
    return n;
}

// Ties go to the lower-numbered category.
static int pick(const int *counts, int n) {
    int best = 0;
    for (int i = 0; i < n; i++)
        if (counts[i] > counts[best]) best = i;
    return best;
}

@interface Tally : NSObject
@property int i, n;
@end

@implementation Tally
@end

// CSP	a process body; tallies is a channel of Tally objects (Go: chan *Tally)
void countCategory(int i, NSArray<NSString *> *words, NSSet<NSString *> *c, Chan<Tally *> *tallies) {
    Tally *t = [Tally new];
    t.i = i;
    t.n = count(words, c);
    // CSP	send this category's count (Go: tallies <- t); the buffer has room, so no wait
    [tallies send:t];
}

// CSP	a process body; out is a channel of [doc, category] pairs
void sortDoc(int d, NSString *dir, NSArray<NSSet<NSString *> *> *cs, Chan<NSArray<NSNumber *> *> *out) {
    NSArray<NSString *> *words = readWords(docPath(dir, d));
    // CSP	a buffered channel with one slot per category, like Go's make(chan *Tally, n)
    Chan<Tally *> *tallies = chan(cs.count);
    for (NSUInteger i = 0; i < cs.count; i++)
        // CSP	start one process per category to count its words in this document
        go(countCategory((int)i, words, cs[i], tallies));
    int counts[cs.count];
    for (NSUInteger i = 0; i < cs.count; i++) {
        // CSP	wait for the next category count, in any order (Go: <-tallies)
        Tally *t = [tallies receive];
        counts[t.i] = t.n;
    }
    // CSP	send [doc, best category] back to main (Go: out <- ...); waits for main to take it
    [out send:@[@(d), @(pick(counts, (int)cs.count))]];
}

static double micros(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static double trial(NSString *dir, NSArray<NSSet<NSString *> *> *cs, BOOL linear, FILE *null) {
    double t0 = micros();
    int result[D];
    if (linear) {
        for (int d = 0; d < D; d++) {
            @autoreleasepool {
                NSArray<NSString *> *words = readWords(docPath(dir, d));
                int counts[cs.count];
                for (NSUInteger i = 0; i < cs.count; i++) counts[i] = count(words, cs[i]);
                result[d] = pick(counts, (int)cs.count);
            }
        }
    } else {
        // CSP	make an unbuffered channel for the results, like Go's make(chan []int)
        Chan<NSArray<NSNumber *> *> *out = chan();
        for (int d = 0; d < D; d++)
            // CSP	start one process per document (Go: go sortDoc(d, dir, cs, out))
            go(sortDoc(d, dir, cs, out));
        for (int i = 0; i < D; i++) {
            // CSP	wait for the next sorted document, in whatever order they finish (Go: <-out)
            NSArray<NSNumber *> *s = [out receive];
            result[s[0].intValue] = s[1].intValue;
        }
    }
    int totals[cs.count];
    memset(totals, 0, sizeof totals);
    for (int d = 0; d < D; d++) {
        totals[result[d]]++;
        fprintf(null, "%d %d\n", d, result[d]);
    }
    fprintf(null, "totals [");
    for (NSUInteger i = 0; i < cs.count; i++) fprintf(null, i ? " %d" : "%d", totals[i]);
    fprintf(null, "]\n");
    fflush(null);
    return micros() - t0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int a = 1;
        BOOL linear = argc > a && !strcmp(argv[a], "-linear");
        if (linear) a++;
        int trials = argc > a ? atoi(argv[a]) : 1;
        FILE *null = fopen(argc > a + 1 ? argv[a + 1] : "/dev/null", "w");
        NSArray<NSSet<NSString *> *> *cs = loadCategories(@"data/categories.txt");
        for (int t = 0; t < trials; t++) {
            @autoreleasepool {
                printf("%.1f\n", trial(@"data/docs", cs, linear, null));
            }
        }
    }
    return 0;
}
