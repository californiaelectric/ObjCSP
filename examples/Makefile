CC     = clang
CFLAGS = -fobjc-arc -O2 -Wall
LDLIBS = -framework Foundation -lsqlite3
LIB    = ../CSP.m ../CSPSched.m ../csp_x86_64.S ../csp_arm64.S

all: verify objects

verify: verify.m $(LIB) ../CSP.h ../CSPSched.h
	$(CC) $(CFLAGS) -o $@ verify.m $(LIB) $(LDLIBS)

objects: objects.m $(LIB) ../CSP.h ../CSPSched.h
	$(CC) $(CFLAGS) -o $@ objects.m $(LIB) -framework Foundation

clean:
	rm -f verify objects people.db

.PHONY: all clean
