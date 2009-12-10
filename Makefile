SHELL=/bin/sh

EFLAGS=-pa ebin

LUA=cd ../moxilua && lua -l luarocks.require

.PHONY: ebins

all: ebins

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make
	cp src/emoxi.app ebin

clean:
	rm -f tmp/*.cov.html erl_crash.dumpg
	rm -rf test/log
	rm -rf ebin

test: test_unit

test_unit:
	erl -pa ebin -noshell -s mc_test test -s init stop

test_boot:
	erl -boot start_sasl -pa ebin -s emoxi start -emoxi config test.cfg

test_main:
	erl -pa ebin -noshell -s mc_test main

test_client_ascii:
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11300
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11400
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11233
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11244

test_client_binary:
	$(LUA) protocol_memcached/test_client_binary.lua localhost:11600
	$(LUA) protocol_memcached/test_client_binary.lua localhost:11244

test_client: test_client_ascii test_client_binary

cucumber:
	erl -pa ebin -noshell -s mc_test cucumber -s init stop

dialyzer: ebins
	dialyzer -pa ebin -I include -r .


