SHELL=/bin/sh

# Emoxi relies on some of the modules contained in ns_server, it
# is assumed that somewhere on the system under tests there is a built
# ns_server repo, these values can be overridded by using -e on the make
# command
NS_SERVER_REPO=../ns_server
NS_SERVER_EBIN=$(NS_SERVER_REPO)/ebin

EFLAGS=-pa ebin $(NS_SERVER_EBIN)

LUA=cd ../moxilua && lua -l luarocks.require

MEMCAPABLE_SCRIPT=./test/memcapable_test.sh

MEMCAPABLE=/usr/local/bin/memcapable

MEMCACHED=/usr/local/bin/memcached

TMP_DIR=./tmp

TMP_VER=$(TMP_DIR)/version_num.tmp

MEMCAPABLE_HOST=127.0.0.1

MEMCAPABLE_PORT=11211

.PHONY: ebins

all: ebins test

bdist: clean ebins
	git describe | sed s/-/_/g > $(TMP_VER)
	tar --directory=.. -czf emoxi_`cat $(TMP_VER)`.tar.gz emoxi/ebin
	echo created emoxi_`cat $(TMP_VER)`.tar.gz

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make
	cp src/*.app ebin

$(TMP_DIR):
	mkdir -p $(TMP_DIR);

clean:
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/memcapable*
	rm -f $(TMP_DIR)/*.cov.html
	rm -f erl_crash.dump
	rm -rf test/log
	rm -rf ebin
	rm -f emoxi_*.tar.gz

test: test_unit cucumber

test_full: test memcapable

test_unit: ebins $(NS_SERVER_EBIN)
	erl $(EFLAGS) -noshell -s mc_test test -s init stop -kernel error_logger silent

test_unit_verbose: ebins $(NS_SERVER_EBIN)
	erl $(EFLAGS) -noshell -s mc_test test -s init stop

test_main: ebin $(NS_SERVER_EBIN)
	erl $(EFLAGS) -s mc_test main -noshell

test_main_shell: ebin $(NS_SERVER_EBIN)
	erl $(EFLAGS) -s mc_test main

test_main_mock: ebin $(NS_SERVER_EBIN)
	erl $(EFLAGS) -s mc_test main_mock

test_main_mock_driver: ebin $(NS_SERVER_EBIN)
	python ./test/emoxi_test.py

test_load_gen: ebin $(NS_SERVER_EBIN)
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

cucumber: ebin $(NS_SERVER_EBIN)
	erl $(EFLAGS) -noshell -s mc_test cucumber -s init stop

dialyzer: ebin $(NS_SERVER_EBIN)
	dialyzer -pa ebin -I include -r .

memcapable: ebins $(MEMCAPABLE) $(MEMCACHED) $(MEMCAPABLE_SCRIPT) $(TMP_DIR) $(NS_SERVER_EBIN)
	$(SHELL) $(MEMCAPABLE_SCRIPT) -c $(MEMCAPABLE) -m $(MEMCACHED) -d $(TMP_DIR) -h $(MEMCAPABLE_HOST) -p $(MEMCAPABLE_PORT)
