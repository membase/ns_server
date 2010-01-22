# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
SHELL=/bin/sh

EFLAGS=-pa ./ebin ./deps/*/ebin ./deps/*/deps/*/ebin

TMP_DIR=./tmp

TMP_VER=$(TMP_DIR)/version_num.tmp

.PHONY: ebins ebin_version ebin_app

all: ebins test deps_all

deps_all:
	$(MAKE) -C deps/emoxi all
	$(MAKE) -C deps/menelaus all

clean_all:
	$(MAKE) -C deps/emoxi clean
	$(MAKE) -C deps/menelaus clean

ebins: ebin_version ebin_app
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make

ebin_version:
	test -d ebin || mkdir ebin
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)
	echo "{ns_server, \"`cat $(TMP_VER)`\"}." > ebin/ns_info.version

ebin_app: ebin_version
	sed s/0.0.0/`cat $(TMP_VER)`/g src/ns_server.app.src > ebin/ns_server.app

clean:
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/*.cov.html
	rm -f cov.html
	rm -f erl_crash.dump
	rm -f ns_server_*.tar.gz
	rm -f src/ns_server.app
	rm -rf test/log
	rm -rf ebin

bdist: clean ebins
	tar --directory=.. -czf ns_server_`cat $(TMP_VER)`.tar.gz ns_server/ebin
	echo created ns_server_`cat $(TMP_VER)`.tar.gz

test: test_unit

test_unit: ebins
	erl $(EFLAGS) -noshell -s ns_server_test test -s init stop -kernel error_logger silent

dialyzer: ebins
	dialyzer -pa ebin -r .

