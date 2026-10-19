# The scheduler spike, 2026-10-18 -- see words.txt, The scheduler.
#
#   ./findslot        which thread-local slot holds the autorelease pool
#   ./spike noswap    coroutines interleaving pools WITHOUT swapping it:
#                     the runtime aborts ("pool page corrupted") -- expected
#   ./spike           with swapping: 100 rounds, then switch timings

CC     = clang
CFLAGS = -fobjc-arc -O2 -Wall
LDLIBS = -framework Foundation

all: findslot spike

findslot: findslot.m
	$(CC) $(CFLAGS) -O1 -o $@ findslot.m $(LDLIBS)

spike: spike.m switch.s
	$(CC) $(CFLAGS) -o $@ spike.m switch.s $(LDLIBS)

clean:
	rm -f findslot spike

.PHONY: all clean
