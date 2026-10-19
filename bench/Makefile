CC      = clang
CFLAGS  = -fobjc-arc -O2 -Wall
LDLIBS  = -framework Foundation

all: cooper-go cooper-golinear cooper-objcsp cooper-linear models-go models-objcsp docs-go docs-objcsp

cooper-go: cooper.go
	go build -o $@ cooper.go

cooper-golinear: linear.go
	go build -o $@ linear.go

cooper-objcsp: cooper.m lorem.h ../CSP.m ../CSPSched.m ../csp_x86_64.S ../CSP.h ../CSPSched.h
	$(CC) $(CFLAGS) -o $@ cooper.m ../CSP.m ../CSPSched.m ../csp_x86_64.S $(LDLIBS)

cooper-linear: linear.m lorem.h
	$(CC) $(CFLAGS) -o $@ linear.m $(LDLIBS)

models-go: models.go
	go build -o $@ models.go

models-objcsp: models.m ../CSP.m ../CSPSched.m ../csp_x86_64.S ../CSP.h ../CSPSched.h
	$(CC) $(CFLAGS) -o $@ models.m ../CSP.m ../CSPSched.m ../csp_x86_64.S $(LDLIBS)

docs-go: docs.go
	go build -o $@ docs.go

docs-objcsp: docs.m ../CSP.m ../CSPSched.m ../csp_x86_64.S ../CSP.h ../CSPSched.h
	$(CC) $(CFLAGS) -o $@ docs.m ../CSP.m ../CSPSched.m ../csp_x86_64.S $(LDLIBS)

# The documents for docs-go and docs-objcsp.
data: gen_docs.py
	python3 gen_docs.py data

clean:
	rm -f cooper-go cooper-golinear cooper-objcsp cooper-linear models-go models-objcsp docs-go docs-objcsp

.PHONY: all clean data
