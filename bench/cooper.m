// cooper.m -- the ObjCSP version of the COOPER benchmark, line for line
// with cooper.go.
//
//     ./cooper-objcsp [trials [outfile]]

#import "lorem.h"
#import "../CSP.h"

enum { N = 1000 };

void cooper(Chan<NSString *> *in, Chan<NSString *> *out) {
    [out send:cooperize([in receive])];
}

static double trial(NSString *block, FILE *null) {
    double t0 = micros();
    Chan<NSString *> *in = chan();
    Chan<NSString *> *out = chan();
    for (int i = 0; i < N; i++)
        go(cooper(in, out));
    for (int i = 0; i < N; i++)
        [in send:block];
    for (int i = 0; i < N; i++)
        dump(null, [out receive]);
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
