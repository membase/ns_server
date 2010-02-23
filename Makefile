# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
SHELL=/bin/sh

EFLAGS=-pa ./ebin ./deps/*/ebin ./deps/*/deps/*/ebin

TMP_DIR=./tmp

TMP_VER=$(TMP_DIR)/version_num.tmp

.PHONY: ebins ebin_app version

all: ebins test deps_all

deps_all:
	(cd deps/emoxi && $(MAKE) ebins)
	(cd deps/menelaus && $(MAKE) all)

ebins: ebin_app
	test -d ebin || mkdir ebin
	erl -noinput +B $(EFLAGS) -eval 'case make:all() of up_to_date -> halt(0); error -> halt(1) end.'

ebin_app: version
	test -d ebin || mkdir ebin
	sed s/0.0.0/`cat $(TMP_VER)`/g src/ns_server.app.src > ebin/ns_server.app
	sed s/0.0.0/`cat $(TMP_VER)`/g src/dist_manager.app.src > ebin/dist_manager.app

version:
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

bdist: clean ebins deps_all
	(cd .. && tar cf -  \
                          ns_server/ebin \
                          ns_server/deps/emoxi/ebin \
                          ns_server/deps/menelaus/ebin \
                          ns_server/deps/menelaus/deps/mochiweb/ebin \
                          ns_server/deps/menelaus/priv/public | gzip -9 -c > \
                          ns_server/ns_server_`cat ns_server/$(TMP_VER)`.tar.gz )
	echo created ns_server_`cat $(TMP_VER)`.tar.gz

clean clean_all:
	@(cd deps/emoxi && $(MAKE) clean)
	@(cd deps/menelaus && $(MAKE) clean)
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/*.cov.html
	rm -f cov.html
	rm -f erl_crash.dump
	rm -f ns_server_*.tar.gz
	rm -f src/ns_server.app
	rm -rf test/log
	rm -rf ebin

test: test_unit

test_unit: ebins
	erl $(EFLAGS) -noshell -s ns_server_test test -s init stop -kernel error_logger silent

dialyzer: ebins
	dialyzer -pa ebin -r .

