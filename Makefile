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

deps_mlockall:
	(cd deps/mlockall; $(MAKE))

deps_ns_babysitter: deps_ale
	(cd deps/ns_babysitter; $(MAKE))

prebuild_vbmap:
	cd deps/vbmap && GOOS=linux GOARCH=386 go build -o ../../priv/i386-linux-vbmap
	cd deps/vbmap && GOOS=darwin GOARCH=386 go build -o ../../priv/i386-darwin-vbmap
	cd deps/vbmap && GOOS=windows GOARCH=386 go build -o ../../priv/i386-win32-vbmap.exe

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq (Linux,$(UNAME_S))
ifneq ($(or $(findstring x86_64,$(UNAME_M)),$(findstring i686,$(UNAME_M))),)
VBMAP_BINARY := priv/i386-linux-vbmap
endif
endif

ifeq (Darwin,$(UNAME_S))
VBMAP_BINARY := priv/i386-darwin-vbmap
endif

ifneq ($(or $(findstring CYGWIN,$(UNAME_S)),$(findstring WOW64,$(UNAME_S))),)
VBMAP_BINARY := priv/i386-win32-vbmap.exe
VBMAP_EXEEXT := .exe
endif

ifdef VBMAP_BINARY

deps_vbmap:
	@echo "Using precompiled vbmap tool at $(VBMAP_BINARY)"

else

VBMAP_BINARY := deps/vbmap/vbmap
deps_vbmap:
	cd deps/vbmap && (go build -x || gccgo -Os -g *.go -o vbmap)

endif

deps_all: deps_smtp deps_erlwsh deps_ale deps_mlockall deps_ns_babysitter deps_vbmap

docs:
	priv/erldocs $(DOC_DIR)

ebins: src/ns_server.app.src deps_all
	$(REBAR) compile

src/ns_server.app.src: src/ns_server.app.src.in $(TMP_VER)
	(sed s/0.0.0/'$(if $(PRODUCT_VERSION),$(PRODUCT_VERSION),$(shell cat $(TMP_VER)))$(if $(PRODUCT_LICENSE),-$(PRODUCT_LICENSE))'/g $< > $@) || (rm $@ && false)

priv/public/js/all-images.js: priv/public/images priv/public/images/spinner scripts/build-all-images.sh
	scripts/build-all-images.sh >$@ || (rm $@ && false)

$(TMP_VER):
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

REST_PREFIX := $(DESTDIR)$(PREFIX)
NS_SERVER := $(DESTDIR)$(PREFIX)/ns_server

install: all ebucketmigrator $(TMP_VER) fail-unless-configured
	$(MAKE) do-install "PREFIX=$(strip $(shell . `pwd`/.configuration && echo $$prefix))"

NS_SERVER_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ns_server

PREFIX_FOR_CONFIG ?= $(PREFIX)

COUCHBASE_DB_DIR ?= $(PREFIX)/var/lib/couchbase/data

ERLWSH_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/erlwsh
GEN_SMTP_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/gen_smtp
ALE_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ale
MLOCKALL_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/mlockall
NS_BABYSITTER_LIBDIR := $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ns_babysitter

do-install:
	echo $(DESTDIR)$(PREFIX)
	rm -rf $(DESTDIR)$(PREFIX)/lib/ns_server/erlang/lib/ns_server*
	mkdir -p $(NS_SERVER_LIBDIR)
	cp -r ebin $(NS_SERVER_LIBDIR)/
	mkdir -p $(NS_SERVER_LIBDIR)/priv
	cp -r priv/public $(NS_SERVER_LIBDIR)/priv/
	cp priv/i386-linux-godu priv/i386-win32-godu.exe $(NS_SERVER_LIBDIR)/priv/
	mkdir -p $(ERLWSH_LIBDIR)
	cp -r deps/erlwsh/ebin $(ERLWSH_LIBDIR)/
	cp -r deps/erlwsh/priv $(ERLWSH_LIBDIR)/
	mkdir -p $(GEN_SMTP_LIBDIR)
	cp -r deps/gen_smtp/ebin $(GEN_SMTP_LIBDIR)/
	mkdir -p $(ALE_LIBDIR)
	cp -r deps/ale/ebin $(ALE_LIBDIR)/
	mkdir -p $(NS_BABYSITTER_LIBDIR)
	cp -r deps/ns_babysitter/ebin $(NS_BABYSITTER_LIBDIR)/
	mkdir -p $(MLOCKALL_LIBDIR)
	cp -r deps/mlockall/ebin $(MLOCKALL_LIBDIR)/
	[ ! -d deps/mlockall/priv ] || cp -r deps/mlockall/priv $(MLOCKALL_LIBDIR)/
	cp -r $(VBMAP_BINARY) $(DESTDIR)$(PREFIX)/bin/vbmap$(VBMAP_EXEEXT)
	mkdir -p $(DESTDIR)$(PREFIX)/etc/couchbase
	sed -e 's|@DATA_PREFIX@|$(PREFIX_FOR_CONFIG)|g' -e 's|@BIN_PREFIX@|$(PREFIX_FOR_CONFIG)|g' \
		 <etc/static_config.in >$(DESTDIR)$(PREFIX)/etc/couchbase/static_config
	touch $(DESTDIR)$(PREFIX)/etc/couchbase/config
	mkdir -p $(DESTDIR)$(PREFIX)/bin/
	sed -e 's|@PREFIX@|$(PREFIX)|g' <couchbase-server.sh.in >$(DESTDIR)$(PREFIX)/bin/couchbase-server
	cp cbbrowse_logs $(DESTDIR)$(PREFIX)/bin/cbbrowse_logs
	cp cbcollect_info $(DESTDIR)$(PREFIX)/bin/cbcollect_info
	chmod +x $(DESTDIR)$(PREFIX)/bin/couchbase-server $(DESTDIR)$(PREFIX)/bin/cbbrowse_logs $(DESTDIR)$(PREFIX)/bin/cbcollect_info
	mkdir -p -m 0770 $(DESTDIR)$(PREFIX)/var/lib/couchbase
	mkdir -p -m 0770 $(DESTDIR)$(PREFIX)/var/lib/couchbase/logs
	cp ebucketmigrator $(DESTDIR)$(PREFIX)/bin/ebucketmigrator
	chmod +x $(DESTDIR)$(PREFIX)/bin/ebucketmigrator
	cp scripts/cbdump-config $(DESTDIR)$(PREFIX)/bin/
	cp scripts/dump-guts $(DESTDIR)$(PREFIX)/bin/
	mkdir -p $(DESTDIR)$(PREFIX)/etc/couchdb/default.d
	sed -e 's|@COUCHBASE_DB_DIR@|$(COUCHBASE_DB_DIR)|g' <etc/capi.ini.in >$(DESTDIR)$(PREFIX)/etc/couchdb/default.d/capi.ini
	cp etc/geocouch.ini.in $(DESTDIR)$(PREFIX)/etc/couchdb/default.d/geocouch.ini

clean clean_all:
	@(cd deps/gen_smtp && $(MAKE) clean)
	@(cd deps/erlwsh && $(MAKE) clean)
	@(cd deps/ale && $(MAKE) clean)
	@(cd deps/mlockall && $(MAKE) clean)
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/*.cov.html
	rm -f cov.html
	rm -f ebucketmigrator
	rm -f erl_crash.dump
	rm -f ns_server_*.tar.gz
	rm -f src/ns_server.app
	rm -f src/ns_babysitter.app
	rm -rf test/log
	rm -rf ebin
	rm -rf docs
	rm -f deps/vbmap/vbmap

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
          --apps compiler crypto erts inets kernel os_mon sasl ssl stdlib xmerl \
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
            $(realpath $(COUCH_PATH)/src/mapreduce) \
            deps/ns_babysitter/ebin

dialyzer_obsessive: all $(COUCHBASE_PLT)
	$(MAKE) do-dialyzer DIALYZER_FLAGS="-Wunmatched_returns -Werror_handling -Wrace_conditions -Wbehaviours -Wunderspecs " COUCH_PATH="$(shell . `pwd`/.configuration && echo $$couchdb_src)"

Features/Makefile:
	(cd features && ../test/parallellize_features.rb) >features/Makefile

.PHONY : features/Makefile

ebucketmigrator: ebins deps_all
	erl -noshell -noinput -pa ebin -s misc build_ebucketmigrator -s init stop
