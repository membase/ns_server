SHELL=/bin/sh

.PHONY: ebins

all: ebins

ebins:
	test -d ebin || mkdir ebin
	erl -noinput +B $(EFLAGS) -eval 'case make:all() of up_to_date -> halt(0); error -> halt(1) end.'

clean:
	rm -rf ebin
