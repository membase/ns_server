SHELL=/bin/sh

EFLAGS=-pa ebin

LUA=cd ../moxilua && lua -l luarocks.require

MEMCAPABLE_SCRIPT=./test/memcapable_test.sh

MEMCAPABLE=/usr/local/bin/memcapable

MEMCACHED=/usr/local/bin/memcached

TMP_DIR=./tmp

.PHONY: ebins

all: ebins test

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make
	cp src/emoxi.app ebin

$(TMP_DIR):
	mkdir -p $(TMP_DIR);

clean:
	rm -f $(TMP_DIR)/*.cov.html erl_crash.dumpg
	rm -rf test/log
	rm -rf ebin
	rm -f $(TMP_DIR)/memcapable*

test: test_unit cucumber memcapable test_boot

test_unit: ebins
	erl $(EFLAGS) -noshell -s mc_test test -s init stop -kernel error_logger silent

test_unit_verbose: ebins
	erl $(EFLAGS) -noshell -s mc_test test -s init stop

test_boot: ebins
	erl -boot start_sasl $(EFLAGS) -s emoxi start -emoxi config config_test.cfg

test_main: ebins
	erl $(EFLAGS) -noshell -s mc_test main

test_load_gen: ebins
	erl $(EFLAGS) -s load_gen_mc main

test_client_ascii:
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11300
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11400
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11233
	$(LUA) protocol_memcached/test_client_ascii.lua localhost:11244

test_client_binary:
	$(LUA) protocol_memcached/test_client_binary.lua localhost:11600
	$(LUA) protocol_memcached/test_client_binary.lua localhost:11244

test_client: test_client_ascii test_client_binary

cucumber: ebins
	erl $(EFLAGS) -noshell -s mc_test cucumber -s init stop

dialyzer: ebins
	dialyzer -pa ebin -I include -r .

memcapable: ebins $(MEMCAPABLE) $(MEMCACHED) $(MEMCAPABLE_SCRIPT) $(TMP_DIR)
	$(SHELL) $(MEMCAPABLE_SCRIPT) -c $(MEMCAPABLE) -m $(MEMCACHED) -d $(TMP_DIR) -h 127.0.0.1 -p 11244
