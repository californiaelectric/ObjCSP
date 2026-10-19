// fanout.m -- a distributed worker, written as a client of the library.
//
// Scores a text file against several vocabularies at once: one process
// per vocabulary, each answering on one shared channel, and exactly as
// many answers collected as processes started.
//
//     ./fanout words.txt

#import "CSP.h"

@interface WordScore : NSObject
@property NSString *name;
@property int score;
@end

@implementation WordScore
@end

// Non-overlapping occurrences of w in t, like Go's strings.Count.
static int count(NSString *t, NSString *w) {
    NSString *rest = [t stringByReplacingOccurrencesOfString:w withString:@""];
    return (int)((t.length - rest.length) / w.length);
}

void scoreWords(NSString *t, NSArray<NSString *> *v, Chan<WordScore *> *c) {
    WordScore *r = [WordScore new];
    r.name = v[0];
    for (NSUInteger i = 1; i < v.count; i++)
        r.score += count(t, v[i]);
    [c send:r];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: fanout file\n");
            return 2;
        }
        NSString *text = [NSString stringWithContentsOfFile:@(argv[1])
                                                      encoding:NSUTF8StringEncoding error:NULL];
        if (!text) {
            fprintf(stderr, "fanout: can't read %s\n", argv[1]);
            return 1;
        }
        text = text.lowercaseString;

        NSArray<NSArray<NSString *> *> *lists = @[
            @[@"channels",  @"chan", @"send", @"receive", @"close"],
            @[@"processes", @"process", @"thread", @"go("],
            @[@"choice",    @"alt", @"case", @"otherwise", @"after"],
            @[@"structs",   @"struct", @"parcel", @"class"],
        ];

        NSUInteger nv = lists.count;
        Chan<WordScore *> *scores = chan(nv);
        for (NSArray<NSString *> *v in lists)
            go(scoreWords(text, v, scores));

        int best = 0;
        NSString *bestName = @"unknown";
        for (NSUInteger i = 0; i < nv; i++) {
            WordScore *score = [scores receive];
            printf("%-10s %4d\n", score.name.UTF8String, score.score);
            if (score.score >= best) {
                best = score.score;
                bestName = score.name;
            }
        }
        printf("top: %s\n", bestName.UTF8String);
    }
    return 0;
}
