// linear.m -- the sequential Objective-C version of the COOPER benchmark:
// the same work as 1,000 plain calls on main, no processes, no channels.
//
//     ./cooper-linear [trials [outfile]]

#import "lorem.h"

enum { N = 1000 };

static double trial(NSString *block, FILE *null) {
    double t0 = micros();
    for (int i = 0; i < N; i++)
        dump(null, cooperize(block));
    fflush(null);
    return micros() - t0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int trials = argc > 1 ? atoi(argv[1]) : 1;
        FILE *null = fopen(argc > 2 ? argv[2] : "/dev/null", "w");    // a file in place of /dev/null, to check the output
        NSString *block = lorem();
        for (int t = 0; t < trials; t++) {
            @autoreleasepool {
                printf("%.1f\n", trial(block, null));
            }
        }
    }
    return 0;
}
