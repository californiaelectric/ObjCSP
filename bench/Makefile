CC      = clang
CFLAGS  = -fobjc-arc -O2 -Wall
LDLIBS  = -framework Foundation

all: cooper-go cooper-objcsp cooper-linear

cooper-go: cooper.go
	go build -o $@ cooper.go

cooper-objcsp: cooper.m lorem.h ../CSP.m ../CSP.h
	$(CC) $(CFLAGS) -o $@ cooper.m ../CSP.m $(LDLIBS)

cooper-linear: linear.m lorem.h
	$(CC) $(CFLAGS) -o $@ linear.m $(LDLIBS)

clean:
	rm -f cooper-go cooper-objcsp cooper-linear

.PHONY: all clean
