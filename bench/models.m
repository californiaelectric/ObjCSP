// models.m -- the "many small models" benchmark, ObjCSP version, line for
// line with models.go. See there for what it does.
//
//     ./models-objcsp [-linear] [trials [outfile]]
//
// -linear runs the same work as plain calls on main, with no processes.

#import <Foundation/Foundation.h>
#import <time.h>
#import "../CSP.h"

enum { S = 400, F = 256, K = 1000, E = 10 };

// The same generator as models.go, so both make the same data.
static double next(uint64_t *r) {
    *r = *r * 6364136223846793005ULL + 1442695040888963407ULL;
    return (double)(*r >> 11) / (double)(1ULL << 53) * 2 - 1;
}

static void makeData(double *x, double *y) {
    uint64_t r = 42;
    for (int i = 0; i < S * F; i++) x[i] = next(&r);
    double h[F];
    for (int k = 0; k < K; k++) {
        for (int f = 0; f < F; f++) h[f] = next(&r);
        for (int s = 0; s < S; s++) {
            double d = 0;
            for (int f = 0; f < F; f++) d += h[f] * x[s * F + f];
            y[k * S + s] = d >= 0 ? 1 : -1;
        }
    }
}

@interface Model : NSObject
@property int k, mistakes;
@property double sum;
@end

@implementation Model
@end

static Model *train(int k, const double *x, const double *y) {
    double w[F] = {0}, b = 0;
    int mistakes = 0;
    for (int e = 0; e < E; e++) {
        mistakes = 0;
        for (int s = 0; s < S; s++) {
            const double *row = x + s * F;
            double d = b;
            for (int f = 0; f < F; f++) d += w[f] * row[f];
            double t = y[k * S + s];
            if (d * t <= 0) {
                mistakes++;
                for (int f = 0; f < F; f++) w[f] += t * row[f];
                b += t;
            }
        }
    }
    double sum = b;
    for (int f = 0; f < F; f++) sum += w[f];
    Model *m = [Model new];
    m.k = k;
    m.mistakes = mistakes;
    m.sum = sum;
    return m;
}

// CSP	a process body; out is a channel of Models (Go: out chan *Model)
void trainer(int k, const double *x, const double *y, Chan<Model *> *out) {
    // CSP	train model k, then send it on out (Go: out <- ...); waits for main to take it
    [out send:train(k, x, y)];
}

static double micros(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static double trial(const double *x, const double *y, BOOL linear, FILE *null) {
    double t0 = micros();
    NSMutableArray<Model *> *res = [NSMutableArray arrayWithCapacity:K];
    for (int k = 0; k < K; k++) [res addObject:(Model *)[NSNull null]];
    if (linear) {
        for (int k = 0; k < K; k++) res[k] = train(k, x, y);
    } else {
        // CSP	make an unbuffered channel of Models, like Go's make(chan *Model)
        Chan<Model *> *out = chan();
        for (int k = 0; k < K; k++)
            // CSP	start one process per model (Go: go trainer(k, x, y, out))
            go(trainer(k, x, y, out));
        for (int i = 0; i < K; i++) {
            // CSP	wait for the next finished model, in whatever order they finish (Go: <-out)
            Model *m = [out receive];
            res[m.k] = m;
        }
    }
    for (Model *m in res) fprintf(null, "%d %d %.9f\n", m.k, m.mistakes, m.sum);
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
        double *x = malloc(sizeof(double) * S * F), *y = malloc(sizeof(double) * K * S);
        makeData(x, y);
        for (int t = 0; t < trials; t++) {
            @autoreleasepool {
                printf("%.1f\n", trial(x, y, linear, null));
            }
        }
    }
    return 0;
}
