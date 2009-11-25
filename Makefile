SHELL=/bin/sh

EFLAGS=-pa ebin

.PHONY: ebins

all: ebins

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make

clean:
	rm -f tmp/*.cov.html erl_crash.dumpg
	rm -rf ebin

test:
	erl -pa ebin -noshell -s mc_test test -s init stop