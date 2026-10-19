CC      = clang
CFLAGS  = -fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter
LDLIBS  = -framework Foundation

all: csptest fanout

csptest: test.m CSP.m CSP.h
	$(CC) $(CFLAGS) -o $@ test.m CSP.m $(LDLIBS)

check: csptest
	./csptest

# The same tests under ThreadSanitizer, which reports data races.
tsan: test.m CSP.m CSP.h
	$(CC) $(CFLAGS) -O1 -fsanitize=thread -o csptest-tsan test.m CSP.m $(LDLIBS)
	./csptest-tsan

fanout: fanout.m CSP.m CSP.h
	$(CC) $(CFLAGS) -o $@ fanout.m CSP.m $(LDLIBS)

clean:
	rm -rf csptest csptest-tsan fanout *.dSYM

.PHONY: all check tsan clean
