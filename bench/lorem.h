// lorem.h -- shared by the Objective-C versions of the COOPER benchmark.

#import <Foundation/Foundation.h>
#import <time.h>

// 1,000 characters of lorem ipsum, all lowercase -- the same text as
// cooper.go builds.
static NSString *lorem(void) {
    NSArray<NSString *> *words = [@"lorem ipsum dolor sit amet consectetur adipiscing elit sed do "
        "eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam "
        "quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat "
        "duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu "
        "fugiat nulla pariatur excepteur sint occaecat cupidatat non proident sunt in culpa "
        "qui officia deserunt mollit anim id est laborum" componentsSeparatedByString:@" "];
    NSMutableString *b = [NSMutableString new];
    for (NSUInteger i = 0; b.length < 1000; i++) {
        if (i > 0) [b appendString:@" "];
        [b appendString:words[i % words.count]];
    }
    return [b substringToIndex:1000];
}

// Process i's spots: different for each, the same as cooper.go's.
static NSUInteger spot(int i, int k) {
    return (NSUInteger)(i * 7919 + k * 104729) % (1000 - 6 + 1);
}

// Overwrites process i's 5 spots in a copy of the block with "COOPER".
static NSString *cooperize(int i, NSString *block) {
    NSMutableString *s = [block mutableCopy];
    for (int k = 0; k < 5; k++)
        [s replaceCharactersInRange:NSMakeRange(spot(i, k), 6) withString:@"COOPER"];
    return s;
}

static double micros(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static void dump(FILE *null, NSString *s) {
    fputs(s.UTF8String, null);
}
