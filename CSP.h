// CSP.h -- Go-style processes and channels for Objective-C.
//
// See words.txt for the full description. In brief:
//
//     Chan<Score *> *c = chan(n);         make(chan score, n)
//     go(work(x, c));                     go work(x, c)
//     [c send:s];                         c <- s
//     Score *s = [c receive];             s := <-c
//     [c close];  for (Score *s in c)     close(c); for s := range c
//
//     alt {                               select {
//         receive(s, c)   { ... }         case s := <-c:
//         sending(out, v) { ... }         case out <- v:
//         after(2.0)      { ... }         case <-time.After(2 * time.Second):
//         otherwise       { ... }         default:
//     }                                   }
//
// Import this header after any other headers: alt and otherwise are
// macros, and would rewrite those words in anything imported later.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A channel carrying objects of one type. nil can't be sent, so nil from
// receive means the channel is closed and empty.
@interface Chan<ObjectType> : NSObject <NSFastEnumeration>

- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init;    // unbuffered

@property (readonly) NSUInteger capacity;

// Waits until a receiver has taken value (unbuffered), or until there is
// room in the buffer. Sending nil, or on a closed channel, is an error.
- (void)send:(ObjectType)value;

// Waits for a value. Returns nil once the channel is closed and drained.
- (nullable ObjectType)receive;

// No more values. Closing twice is an error.
- (void)close;

@end

// chan() is unbuffered, chan(n) holds up to n values.
Chan *CSPMakeChan(NSUInteger capacity);
#define chan(...) CSPMakeChan(__VA_ARGS__ + 0)

// go(f(x)) runs f(x) as a new process, on its own thread. The variables
// in the call are captured when go runs. go({ ... }) runs a block of
// statements the same way.
void CSPGo(void (^block)(void));
#define go(...) CSPGo(^{ __VA_ARGS__; })


// Parcel -- carries a plain C struct over a channel. Prefer a small class;
// this is for C structs you already have.
@interface Parcel : NSObject
- (instancetype)initWithBytes:(const void *)bytes size:(size_t)size type:(const char *)type;
- (instancetype)init NS_UNAVAILABLE;
@end

void CSPStructFromParcel(Parcel *_Nullable parcel, void *dst, size_t size, const char *type);

#define parcelFromStruct(s) ({                                              \
    __typeof__(s) _cspS = (s);                                              \
    [[Parcel alloc] initWithBytes:&_cspS size:sizeof _cspS                  \
                             type:@encode(__typeof__(_cspS))];              \
})

#define structFromParcel(T, p) ({                                           \
    T _cspT;                                                                \
    CSPStructFromParcel((p), &_cspT, sizeof(T), @encode(T));                \
    _cspT;                                                                  \
})


// alt -- everything below is machinery for the alt macros.
//
// alt is a loop that runs its body twice. On the first pass each case
// registers itself and its body is skipped. Then the library waits until
// one case is ready and does it. On the second pass only that case's body
// runs. Cases are told apart by their order, so every case must be reached
// on both passes: don't put one inside an if.

@class CSPAlt;

CSPAlt *CSPAltBegin(void);
BOOL CSPAltNext(CSPAlt *a);
int CSPAltPass(CSPAlt *a);
long CSPAltIndex(CSPAlt *a);
BOOL CSPAltAddReceive(CSPAlt *a, long i, Chan *_Nullable c);
BOOL CSPAltAddSend(CSPAlt *a, long i, Chan *_Nullable c, id _Nullable value);
BOOL CSPAltAddAfter(CSPAlt *a, long i, double seconds);
BOOL CSPAltAddOtherwise(CSPAlt *a, long i);
BOOL CSPAltFire(CSPAlt *a, long i);
id _Nullable CSPAltValue(CSPAlt *a);

#define alt for (CSPAlt *_cspAlt = CSPAltBegin(); CSPAltNext(_cspAlt); )

// The case macros evaluate their channel and value only on the first pass.
// x is declared with the channel's element type, scoped to the body.
#define receive(x, c)                                                       \
    for (long _cspI = CSPAltIndex(_cspAlt); _cspI >= 0; _cspI = -1)         \
        for (__typeof__([(c) receive]) x = nil;                             \
             CSPAltPass(_cspAlt) == 1                                       \
                 ? CSPAltAddReceive(_cspAlt, _cspI, (c))                    \
                 : (CSPAltFire(_cspAlt, _cspI)                              \
                        && ((x = CSPAltValue(_cspAlt)), (void)x, YES)); )

#define sending(c, v)                                                       \
    for (long _cspI = CSPAltIndex(_cspAlt); _cspI >= 0; _cspI = -1)         \
        while (CSPAltPass(_cspAlt) == 1                                     \
                   ? CSPAltAddSend(_cspAlt, _cspI, (c), (v))                \
                   : CSPAltFire(_cspAlt, _cspI))

#define after(seconds)                                                      \
    for (long _cspI = CSPAltIndex(_cspAlt); _cspI >= 0; _cspI = -1)         \
        while (CSPAltPass(_cspAlt) == 1                                     \
                   ? CSPAltAddAfter(_cspAlt, _cspI, (seconds))              \
                   : CSPAltFire(_cspAlt, _cspI))

#define otherwise                                                           \
    for (long _cspI = CSPAltIndex(_cspAlt); _cspI >= 0; _cspI = -1)         \
        while (CSPAltPass(_cspAlt) == 1                                     \
                   ? CSPAltAddOtherwise(_cspAlt, _cspI)                     \
                   : CSPAltFire(_cspAlt, _cspI))

NS_ASSUME_NONNULL_END
