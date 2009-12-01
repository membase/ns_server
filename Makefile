SHELL=/bin/sh

EFLAGS=-pa ebin

LUA=cd ../moxilua && lua -l luarocks.require

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

test_client_ascii:
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11300
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11400
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11233
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11244

test_client_binary:
	$(LUA) protocol_memcached/test_client_binary.lua localhost:11600
	$(LUA) protocol_memcached/test_client_binary.lua localhost:11244

test_client: test_client_ascii test_client_binary

