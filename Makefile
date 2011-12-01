# Copyright (c) 2011, Couchbase, Inc.
# All rights reserved.
SHELL=/bin/sh

EBIN_PATHS=`find -L "$(PWD)" -name ebin -type d`
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

ifneq (,$(wildcard .configuration))
all: ebins deps_all priv/public/js/all-images.js

fail-unless-configured:
	@true

else
all fail-unless-configured:
	@echo
	@echo "you need to run ./configure with --prefix option to be able to run ns_server"
	@echo
	@false
endif

dist:
	mkdir -p tmp/ns_server-`git describe`
	rm -rf tmp/ns_server-`git describe`/*
	cp configure tmp/ns_server-`git describe`/
	cp -R LICENSE Makefile README* cluster* common* cb* couchbase* rebar* tmp/ns_server-`git describe`/
	cp -R deps doc etc include priv scripts src test tmp/ns_server-`git describe`/
	find tmp/ns_server-`git describe` -name '*.beam' | xargs rm -f
	tar -C tmp -czf ns_server-`git describe`.tar.gz ns_server-`git describe`

deps_smtp:
	(cd deps/gen_smtp && $(MAKE) compile)

deps_erlwsh:
	(cd deps/erlwsh; $(MAKE))

deps_ale:
	(cd deps/ale; $(MAKE))

deps_all: deps_smtp deps_erlwsh deps_ale

docs:
	priv/erldocs $(DOC_DIR)

ebins: src/ns_server.app.src include/replication_infos_ddoc.hrl deps_all
	$(REBAR) compile

src/ns_server.app.src: src/ns_server.app.src.in $(TMP_VER)
	(sed s/0.0.0/'$(if $(PRODUCT_VERSION),$(PRODUCT_VERSION),$(shell cat $(TMP_VER)))'/g $< > $@) || (rm $@ && false)

# NOTE: not depending on scripts/build_replication_infos_ddoc.rb because we're uploading both files to git.
# If you need to rebuild this file, remove it first.
include/replication_infos_ddoc.hrl:
	scripts/build_replication_infos_ddoc.rb >$@ || (rm $@ && false)

rebuild_replication_infos_ddoc:
	rm include/replication_infos_ddoc.hrl
	$(MAKE) include/replication_infos_ddoc.hrl

.PHONY: rebuild_replication_infos_ddoc

ifdef PRODUCT_VERSION
.PHONY: src/ns_server.app.src
endif

priv/public/js/all-images.js: priv/public/images priv/public/images/spinner scripts/build-all-images.sh
	scripts/build-all-images.sh >$@ || (rm $@ && false)

$(TMP_VER):
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

REST_PREFIX := $(DESTDIR)$(PREFIX)
NS_SERVER := $(DESTDIR)$(PREFIX)/ns_server

install: all ebucketmigrator $(TMP_VER) fail-unless-configured
	$(MAKE) do-install "NS_SERVER_VER=$(strip $(shell cat $(TMP_VER)))" "PREFIX=$(strip $(shell . `pwd`/.configuration && echo $$prefix))"

NS_SERVER_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ns_server

ifdef NS_SERVER_VER
NS_SERVER_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ns_server-$(NS_SERVER_VER)

ifeq (,$(DESTDIR)$(PREFIX))
$(error "need PREFIX defined")
endif

endif

PREFIX_FOR_CONFIG ?= $(DESTDIR)$(PREFIX)

ERLWSH_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/erlwsh
GEN_SMTP_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/gen_smtp
ALE_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ale

do-install:
	echo $(DESTDIR)$(PREFIX)
	rm -rf $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ns_server*
	mkdir -p $(NS_SERVER_LIBDIR)
	cp -r ebin $(NS_SERVER_LIBDIR)/
	mkdir -p $(NS_SERVER_LIBDIR)/priv
	cp -r priv/public $(NS_SERVER_LIBDIR)/priv/
	mkdir -p $(ERLWSH_LIBDIR)
	cp -r deps/erlwsh/ebin $(ERLWSH_LIBDIR)/
	cp -r deps/erlwsh/priv $(ERLWSH_LIBDIR)/
	mkdir -p $(GEN_SMTP_LIBDIR)
	cp -r deps/gen_smtp/ebin $(GEN_SMTP_LIBDIR)/
	mkdir -p $(ALE_LIBDIR)
	cp -r deps/ale/ebin $(ALE_LIBDIR)/
	mkdir -p $(DESTDIR)$(PREFIX)/etc/couchbase
	sed -e 's|@DATA_PREFIX@|$(PREFIX_FOR_CONFIG)|g' -e 's|@BIN_PREFIX@|$(PREFIX_FOR_CONFIG)|g' \
		 <etc/static_config.in >$(DESTDIR)$(PREFIX)/etc/couchbase/static_config
	touch $(DESTDIR)$(PREFIX)/etc/couchbase/config
	mkdir -p $(DESTDIR)$(PREFIX)/bin/
	sed -e 's|@PREFIX@|$(DESTDIR)$(PREFIX)|g' <couchbase-server.sh.in >$(DESTDIR)$(PREFIX)/bin/couchbase-server
	sed -e 's|@PREFIX@|$(DESTDIR)$(PREFIX)|g' <cbbrowse_logs.in >$(DESTDIR)$(PREFIX)/bin/cbbrowse_logs
	cp cbcollect_info $(DESTDIR)$(PREFIX)/bin/cbcollect_info
	chmod +x $(DESTDIR)$(PREFIX)/bin/couchbase-server $(DESTDIR)$(PREFIX)/bin/cbbrowse_logs $(DESTDIR)$(PREFIX)/bin/cbcollect_info
	mkdir -p $(DESTDIR)$(PREFIX)/var/lib/couchbase/mnesia
	mkdir -p $(DESTDIR)$(PREFIX)/var/lib/couchbase/logs
	cp priv/init.sql $(DESTDIR)$(PREFIX)/etc/couchbase/
	cp ebucketmigrator $(DESTDIR)$(PREFIX)/bin/ebucketmigrator
	chmod +x $(DESTDIR)$(PREFIX)/bin/ebucketmigrator
	cp scripts/cbdumpconfig.escript $(DESTDIR)$(PREFIX)/bin/
	mkdir -p $(DESTDIR)$(PREFIX)/etc/couchdb/default.d
	cp etc/capi.ini.in $(DESTDIR)$(PREFIX)/etc/couchdb/default.d/capi.ini

clean clean_all:
	@(cd deps/gen_smtp && $(MAKE) clean)
	@(cd deps/erlwsh && $(MAKE) clean)
	@(cd deps/ale && $(MAKE) clean)
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
	rm -rf $(TMP_DIR) data coverage couch logs tmp

distclean: clean dataclean

common_tests: dataclean all
	mkdir -p logs
	erl -noshell -name ctrl@127.0.0.1 -hidden -setcookie nocookie -pa $(EBIN_PATHS) -eval "ct:run_test([{spec, \"./common_tests/common_tests.spec\"}]), init:stop()"

test: ebins
	erl $(EFLAGS) -noshell -kernel error_logger silent -shutdown_time 10000 -eval 'application:start(sasl).' -eval "case t:$(TEST_TARGET)() of ok -> init:stop(); _ -> init:stop(1) end."

# assuming exuberant-ctags
TAGS:
	ctags -eR .

$(NS_SERVER_PLT): | all
	$(MAKE) do_build_plt COUCH_PATH="$(shell . `pwd`/.configuration && echo $$couchdb_src)"

do_build_plt:
	dialyzer --output_plt $(NS_SERVER_PLT) --build_plt -pa ebin --apps compiler crypto erts inets kernel mnesia os_mon sasl ssl stdlib xmerl -c deps/erlwsh/ebin $(COUCH_PATH)/src/couchdb $(COUCH_PATH)/src/mochiweb $(COUCH_PATH)/src/snappy $(COUCH_PATH)/src/etap $(COUCH_PATH)/src/ibrowse $(COUCH_PATH)/src/erlang-oauth

dialyzer: all $(NS_SERVER_PLT)
	dialyzer --plt $(NS_SERVER_PLT) -pa ebin -c ebin

dialyzer_obsessive: all $(NS_SERVER_PLT)
	dialyzer --plt $(NS_SERVER_PLT) -Wunmatched_returns -Werror_handling -Wrace_conditions -Wbehaviours -Wunderspecs -pa ebin -c ebin

dialyzer_rebar: all
	$(REBAR) analyze

Features/Makefile:
	(cd features && ../test/parallellize_features.rb) >features/Makefile

.PHONY : features/Makefile

ebucketmigrator: ebins deps_all
	erl -noshell -noinput -pa ebin -s misc build_ebucketmigrator -s init stop
