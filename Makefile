CC      = clang
CFLAGS  = -fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter
LDLIBS  = -framework Foundation
PREFIX  = /usr/local

all: libcsp.a csptest fanout

# The library: what make install puts in $(PREFIX)/lib, with CSP.h in
# $(PREFIX)/include. A client then builds with
#     clang -fobjc-arc -o prog prog.m -lcsp -framework Foundation
libcsp.a: CSP.m CSP.h
	$(CC) $(CFLAGS) -c -o CSP.o CSP.m
	libtool -static -o $@ CSP.o

install: libcsp.a
	install -d $(PREFIX)/lib $(PREFIX)/include
	install -m 644 libcsp.a $(PREFIX)/lib
	install -m 644 CSP.h $(PREFIX)/include

uninstall:
	rm -f $(PREFIX)/lib/libcsp.a $(PREFIX)/include/CSP.h

csptest: test.m CSP.m CSP.h
	$(CC) $(CFLAGS) -o $@ test.m CSP.m $(LDLIBS)

check: csptest
	./csptest

# The same tests under ThreadSanitizer, which reports data races.
tsan: test.m CSP.m CSP.h
	$(CC) $(CFLAGS) -O1 -fsanitize=thread -o csptest-tsan test.m CSP.m $(LDLIBS)
	./csptest-tsan

# Built the way a client builds: against the library, not its source.
fanout: fanout.m libcsp.a
	$(CC) $(CFLAGS) -I. -o $@ fanout.m -L. -lcsp $(LDLIBS)

clean:
	rm -rf libcsp.a CSP.o csptest csptest-tsan fanout *.dSYM

.PHONY: all install uninstall check tsan clean
