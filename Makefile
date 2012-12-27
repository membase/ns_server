# Copyright (c) 2011, Couchbase, Inc.
# All rights reserved.
SHELL=/bin/sh

COUCHBASE_PLT ?= couchbase.plt

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
	(sed s/0.0.0/'$(if $(PRODUCT_VERSION),$(PRODUCT_VERSION),$(shell cat $(TMP_VER)))$(if $(PRODUCT_LICENSE),-$(PRODUCT_LICENSE))'/g $< > $@) || (rm $@ && false)

# NOTE: not depending on scripts/build_replication_infos_ddoc.rb because we're uploading both files to git.
# If you need to rebuild this file, remove it first.
include/replication_infos_ddoc.hrl:
	scripts/build_replication_infos_ddoc.rb >$@ || (rm $@ && false)

rebuild_replication_infos_ddoc:
	rm -f include/replication_infos_ddoc.hrl
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

PREFIX_FOR_CONFIG ?= $(PREFIX)

COUCHBASE_DB_DIR ?= $(PREFIX)/var/lib/couchbase/data

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
	sed -e 's|@PREFIX@|$(PREFIX)|g' <couchbase-server.sh.in >$(DESTDIR)$(PREFIX)/bin/couchbase-server
	cp cbbrowse_logs $(DESTDIR)$(PREFIX)/bin/cbbrowse_logs
	cp cbcollect_info $(DESTDIR)$(PREFIX)/bin/cbcollect_info
	chmod +x $(DESTDIR)$(PREFIX)/bin/couchbase-server $(DESTDIR)$(PREFIX)/bin/cbbrowse_logs $(DESTDIR)$(PREFIX)/bin/cbcollect_info
	mkdir -p $(DESTDIR)$(PREFIX)/var/lib/couchbase/mnesia
	mkdir -p $(DESTDIR)$(PREFIX)/var/lib/couchbase/logs
	cp ebucketmigrator $(DESTDIR)$(PREFIX)/bin/ebucketmigrator
	chmod +x $(DESTDIR)$(PREFIX)/bin/ebucketmigrator
	cp scripts/cbdump-config $(DESTDIR)$(PREFIX)/bin/
	mkdir -p $(DESTDIR)$(PREFIX)/etc/couchdb/default.d
	sed -e 's|@COUCHBASE_DB_DIR@|$(COUCHBASE_DB_DIR)|g' <etc/capi.ini.in >$(DESTDIR)$(PREFIX)/etc/couchdb/default.d/capi.ini
	cp etc/geocouch.ini.in $(DESTDIR)$(PREFIX)/etc/couchdb/default.d/geocouch.ini

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

TEST_EFLAGS=-pa ./ebin ./deps/*/ebin ./deps/*/deps/*/ebin $(shell . `pwd`/.configuration && echo $$couchdb_src)/src/couchdb

test: ebins
	$(MAKE) do-test COUCH_PATH="$(shell . `pwd`/.configuration && echo $$couchdb_src)"

do-test:
	erl $(TEST_EFLAGS) -pa "$(COUCH_PATH)/src/mochiweb" -noshell -kernel error_logger silent -shutdown_time 10000 -eval 'application:start(sasl).' -eval "case t:$(TEST_TARGET)() of ok -> init:stop(); _ -> init:stop(1) end."

# assuming exuberant-ctags
TAGS:
	ctags -eR .

$(COUCHBASE_PLT): | all
	$(MAKE) do_build_plt COUCH_PATH="$(shell . `pwd`/.configuration && echo $$couchdb_src)"

do_build_plt:
	dialyzer --output_plt $(COUCHBASE_PLT) --build_plt \
          --apps compiler crypto erts inets kernel mnesia os_mon sasl ssl stdlib xmerl \
            $(COUCH_PATH)/src/mochiweb \
            $(COUCH_PATH)/src/snappy $(COUCH_PATH)/src/etap $(realpath $(COUCH_PATH)/src/ibrowse) \
            $(realpath $(COUCH_PATH)/src/lhttpc) \
            $(COUCH_PATH)/src/erlang-oauth deps/erlwsh/ebin deps/gen_smtp/ebin


OTP_RELEASE = $(shell erl -noshell -eval 'io:format("~s~n", [erlang:system_info(otp_release)]), erlang:halt().')
MAYBE_UNDEFINED_CALLBACKS = $(shell echo "$(OTP_RELEASE)" | grep -q "^R1[5-9]B.*$$" && echo -n "-Wno_undefined_callbacks" || echo -n)
dialyzer: all $(COUCHBASE_PLT)
	$(MAKE) do-dialyzer DIALYZER_FLAGS="-Wno_return -Wno_improper_lists $(MAYBE_UNDEFINED_CALLBACKS) $(DIALYZER_FLAGS)" COUCH_PATH="$(shell . `pwd`/.configuration && echo $$couchdb_src)"

do-dialyzer:
	dialyzer --plt $(COUCHBASE_PLT) $(DIALYZER_FLAGS) \
            --apps `ls -1 ebin/*.beam | grep -v couch_log` deps/ale/ebin \
            $(COUCH_PATH)/src/couchdb $(COUCH_PATH)/src/couch_set_view $(COUCH_PATH)/src/couch_view_parser \
            $(COUCH_PATH)/src/couch_index_merger/ebin \
            $(realpath $(COUCH_PATH)/src/mapreduce)

dialyzer_obsessive: all $(COUCHBASE_PLT)
	$(MAKE) do-dialyzer DIALYZER_FLAGS="-Wunmatched_returns -Werror_handling -Wrace_conditions -Wbehaviours -Wunderspecs " COUCH_PATH="$(shell . `pwd`/.configuration && echo $$couchdb_src)"

Features/Makefile:
	(cd features && ../test/parallellize_features.rb) >features/Makefile

.PHONY : features/Makefile

ebucketmigrator: ebins deps_all
	erl -noshell -noinput -pa ebin -s misc build_ebucketmigrator -s init stop
