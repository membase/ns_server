SHELL=/bin/sh

EFLAGS=-pa ebin

.PHONY: ebins

all: ebins

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make

clean:
	rm -f cov.html erl_crash.dump
	rm -rf ebin

test:
	erl -pa ebin -noshell -s mc_test test -s init stop