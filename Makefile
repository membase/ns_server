# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
SHELL=/bin/sh

EFLAGS=-pa ./ebin ./deps/*/ebin ./deps/*/deps/*/ebin

TMP_DIR=./tmp

TMP_VER=$(TMP_DIR)/version_num.tmp

.PHONY: ebins

all: ebins test deps_all

deps_all:
	$(MAKE) -C deps/emoxi all
	$(MAKE) -C deps/menelaus all

clean_all:
	$(MAKE) -C deps/emoxi clean
	$(MAKE) -C deps/menelaus clean

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make
	cp src/*.app ebin

clean:
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/*.cov.html
	rm -f cov.html
	rm -f erl_crash.dump
	rm -f ns_server_*.tar.gz
	rm -rf test/log
	rm -rf ebin

bdist: clean ebins
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)
	tar --directory=.. -czf ns_server_`cat $(TMP_VER)`.tar.gz ns_server/ebin
	echo created ns_server_`cat $(TMP_VER)`.tar.gz

test: test_unit

test_unit: ebins
	erl $(EFLAGS) -noshell -s ns_server_test test -s init stop -kernel error_logger silent

test_main: ebins
	epmd -kill
	erl -name ns_test1 -boot start_sasl $(EFLAGS) -setcookie nocookie -eval 'application:start(ns_server).'

dialyzer: ebins
	dialyzer -pa ebin -r .

