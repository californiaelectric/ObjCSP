CC      = clang
CFLAGS  = -fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter
LDLIBS  = -framework Foundation
PREFIX  = /usr/local

all: libcsp.a csptest fanout

# The library: what make install puts in $(PREFIX)/lib, with CSP.h in
# $(PREFIX)/include. A client then builds with
#     clang -fobjc-arc -o prog prog.m -lcsp -framework Foundation
SRCS    = CSP.m CSPSched.m csp_x86_64.S
HDRS    = CSP.h CSPSched.h

# Universal: one library for Intel and Apple Silicon Macs. (On Apple
# Silicon it runs a thread per process until the scheduler is ported.)
ARCHS   = -arch x86_64 -arch arm64

libcsp.a: $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) $(ARCHS) -c CSP.m CSPSched.m csp_x86_64.S
	libtool -static -no_warning_for_no_symbols -o $@ CSP.o CSPSched.o csp_x86_64.o

install: libcsp.a
	install -d $(PREFIX)/lib $(PREFIX)/include
	install -m 644 libcsp.a $(PREFIX)/lib
	install -m 644 CSP.h $(PREFIX)/include

uninstall:
	rm -f $(PREFIX)/lib/libcsp.a $(PREFIX)/include/CSP.h

csptest: test.m $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ test.m $(SRCS) $(LDLIBS)

check: csptest
	./csptest

# The same tests under ThreadSanitizer, which reports data races.
tsan: test.m $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -O1 -fsanitize=thread -o csptest-tsan test.m $(SRCS) $(LDLIBS)
	./csptest-tsan

# Built the way a client builds: against the library, not its source.
fanout: fanout.m libcsp.a
	$(CC) $(CFLAGS) -I. -o $@ fanout.m -L. -lcsp $(LDLIBS)

clean:
	rm -rf libcsp.a *.o csptest csptest-tsan fanout *.dSYM

.PHONY: all install uninstall check tsan clean
