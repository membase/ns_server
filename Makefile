# Copyright (c) 2011, Membase, Inc.
# All rights reserved.
SHELL=/bin/sh

EBIN_PATHS=`find "$(PWD)" -name ebin -type d`
EFLAGS=-pa ./ebin ./deps/*/ebin ./deps/*/deps/*/ebin

NS_SERVER_PLT ?= ns_server.plt

TMP_DIR=./tmp

TMP_VER=$(TMP_DIR)/version_num.tmp
TEST_TARGET=start

DOC_DIR?=./docs/erldocs

REBAR=./rebar

.PHONY: ebins

# always rebuild TMP_VER just in case someone depends on it be
# up-to-date
.PHONY: $(TMP_VER)

all: ebins deps_all

deps_menelaus:
	(cd deps/menelaus && $(MAKE) all)

deps_smtp:
	(cd deps/gen_smtp && $(MAKE) ebins)

deps_all: deps_menelaus deps_smtp

docs:
	priv/erldocs $(DOC_DIR)

ebins: src/ns_server.app.src
	$(REBAR) compile

src/ns_server.app.src: src/ns_server.app.src.in $(TMP_VER)
	(sed s/0.0.0/`cat $(TMP_VER)`/g $< > $@) || (rm $@ && false)

$(TMP_VER):
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

ifdef PREFIX

REST_PREFIX := $(PREFIX)
NS_SERVER := $(PREFIX)/ns_server

install:
	mkdir -p $(NS_SERVER)
	tar cf - cluster_connect cluster_run mkcouch.sh mbcollect_info \
		ebin \
		deps/*/ebin \
		deps/*/deps/*/ebin \
		deps/menelaus/priv/public \
		deps/menelaus/deps/erlwsh/priv | (cd $(PREFIX)/ns_server && tar xf -)
	mkdir -p ns_server/bin ns_server/lib/memcached
	ln -f -s $(REST_PREFIX)/bin/memcached $(NS_SERVER)/bin/memcached || true
	ln -f -s $(REST_PREFIX)/lib/memcached/default_engine.so $(NS_SERVER)/lib/memcached/default_engine.so || true
	ln -f -s $(REST_PREFIX)/lib/memcached/stdin_term_handler.so $(NS_SERVER)/lib/memcached/stdin_term_handler.so || true
	mkdir -p $(NS_SERVER)/bin/bucket_engine
	ln -f -s $(REST_PREFIX)/lib/bucket_engine.so $(NS_SERVER)/bin/bucket_engine/bucket_engine.so || true
	mkdir -p $(NS_SERVER)/bin/ep_engine
	ln -f -s $(REST_PREFIX)/lib/ep.so $(NS_SERVER)/bin/ep_engine/ep.so || true
	mkdir -p $(NS_SERVER)/bin/moxi
	ln -f -s $(REST_PREFIX)/bin/moxi $(NS_SERVER)/bin/moxi/moxi || true
	mkdir -p $(NS_SERVER)/bin/vbucketmigrator
	ln -f -s $(REST_PREFIX)/bin/vbucketmigrator $(NS_SERVER)/bin/vbucketmigrator/vbucketmigrator || true

endif

bdist: clean ebins deps_all
	(cd .. && tar cf -  \
                          ns_server/mbcollect_info \
                          ns_server/ebin \
                          ns_server/deps/*/ebin \
                          ns_server/deps/*/deps/*/ebin \
                          ns_server/deps/menelaus/priv/public \
                          ns_server/deps/menelaus/deps/erlwsh/priv | gzip -9 -c > \
                          ns_server/ns_server_`cat ns_server/$(TMP_VER)`.tar.gz )
	echo created ns_server_`cat $(TMP_VER)`.tar.gz

clean clean_all:
	@(cd deps/menelaus && $(MAKE) clean)
	@(cd deps/gen_smtp && $(MAKE) clean)
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/*.cov.html
	rm -f cov.html
	rm -f ebucketmigrator
	rm -f erl_crash.dump
	rm -f ns_server_*.tar.gz
	rm -f src/ns_server.app
	rm -rf test/log
	rm -rf ebin
	rm -rf docs

dataclean:
	rm -rf $(TMP_DIR)
	rm -rf Mnesia*
	rm -rf config
	rm -rf data
	rm -rf logs
	rm -rf coverage
	rm -f priv/ip
	rm -rf couch

distclean: clean dataclean

common_tests: dataclean all
	mkdir -p logs
	erl -noshell -name ctrl@127.0.0.1 -setcookie nocookie -pa $(EBIN_PATHS) -eval "ct:run_test([{spec, \"./common_tests/common_tests.spec\"}]), init:stop()"

test: test_$(OS)

test_: test_unit test_menelaus

test_Windows_NT: test_unit test_menelaus

test_unit: ebins
	erl $(EFLAGS) -noshell -kernel error_logger silent -shutdown_time 10000 -eval 'application:start(sasl).' -eval "case t:$(TEST_TARGET)() of ok -> init:stop(); _ -> init:stop(1) end."

test_menelaus: deps/menelaus
	(cd deps/menelaus; $(MAKE) test)

# assuming exuberant-ctags
TAGS:
	ctags -eR .

$(NS_SERVER_PLT):
	dialyzer --output_plt $@ --build_plt -pa ebin --apps compiler crypto erts inets kernel mnesia os_mon sasl ssl stdlib xmerl -c deps/menelaus/deps/mochiweb/ebin deps/menelaus/deps/erlwsh/ebin

dialyzer: all $(NS_SERVER_PLT)
	dialyzer --plt $(NS_SERVER_PLT) -pa ebin -c ebin -c deps/menelaus/ebin

dialyzer_obsessive: all $(NS_SERVER_PLT)
	dialyzer --plt $(NS_SERVER_PLT) -Wunmatched_returns -Werror_handling -Wrace_conditions -Wbehaviours -Wunderspecs -pa ebin -c ebin -c deps/menelaus/ebin

dialyzer_rebar: all
	$(REBAR) analyze

Features/Makefile:
	(cd features && ../test/parallellize_features.rb) >features/Makefile

.PHONY : features/Makefile

parallel_cucumber: features/Makefile
	$(MAKE) -k -C features all_branches

ebucketmigrator: all
	erl -noshell -noinput -pa ebin -s misc build_ebucketmigrator -s init stop