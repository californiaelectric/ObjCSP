// cooper.m -- the ObjCSP version of the COOPER benchmark, line for line
// with cooper.go.
//
//     ./cooper-objcsp [trials [outfile]]

#import "lorem.h"
#import "../CSP.h"

enum { N = 1000 };

// CSP	a process body; in and out are channels of strings (Go: in, out chan string)
void cooper(int i, Chan<NSString *> *in, Chan<NSString *> *out) {
    // CSP	wait for a block on in (Go: <-in), mark it, send it on out (Go: out <- ...)
    [out send:cooperize(i, [in receive])];
}

static double trial(NSString *block, FILE *null) {
    double t0 = micros();
    // CSP	make an unbuffered channel of strings, like Go's make(chan string)
    Chan<NSString *> *in = chan();
    // CSP	another unbuffered channel, for the marked blocks coming back
    Chan<NSString *> *out = chan();
    for (int i = 0; i < N; i++)
        // CSP	start process i (Go: go cooper(i, in, out)); it waits for the block on in
        go(cooper(i, in, out));
    for (int i = 0; i < N; i++)
        // CSP	hand the block to one waiting process; waits until one takes it
        [in send:block];
    for (int i = 0; i < N; i++)
        // CSP	wait for the next marked block from any process (Go: <-out)
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
