// Which thread-local slot holds the autorelease pool's hot page?
#import <Foundation/Foundation.h>
#import <pthread.h>
void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);

enum { SLOTS = 128 };
static void *slot(long k) { void *v; __asm__ volatile("movq %%gs:(,%1,8), %0" : "=r"(v) : "r"(k)); return v; }
static void snap(void **s) { for (long k = 0; k < SLOTS; k++) s[k] = slot(k); }
static void diff(const char *what, void **a, void **b) {
    for (long k = 0; k < SLOTS; k++) if (a[k] != b[k]) printf("  %-28s slot %3ld: %p -> %p\n", what, k, a[k], b[k]);
}
static void *run(void *_) {
    void *s0[SLOTS], *a[SLOTS], *b[SLOTS], *c[SLOTS], *d[SLOTS];
    snap(s0);
    void *tok = objc_autoreleasePoolPush();
    snap(a); diff("push (nothing autoreleased)", s0, a);
    CFAutorelease(CFBridgingRetain([NSObject new]));
    snap(b); diff("first autorelease", a, b);
    objc_autoreleasePoolPop(tok);
    snap(c); diff("pop", b, c);
    printf("  push token %p\n", tok);
    void *tok2 = objc_autoreleasePoolPush();
    CFAutorelease(CFBridgingRetain([NSObject new]));
    snap(d); diff("push + autorelease again", c, d);
    printf("  second token %p\n", tok2);
    objc_autoreleasePoolPop(tok2);
    return NULL;
}
int main(void) {
    printf("macOS %s\n", NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String);
    pthread_t t; pthread_create(&t, NULL, run, NULL); pthread_join(t, NULL);
}
