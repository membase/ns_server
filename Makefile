# Copyright (c) 2011, Membase, Inc.
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
all: ebins deps_all priv/public/js/all-images.js ebucketmigrator

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
	cp -R LICENSE Makefile README* cluster* common* mb* membase* rebar* tmp/ns_server-`git describe`/
	cp -R deps doc etc features include priv scripts src test tmp/ns_server-`git describe`/
	find tmp/ns_server-`git describe` -name '*.beam' | xargs rm -f
	tar -C tmp -czf ns_server-`git describe`.tar.gz ns_server-`git describe`

deps_smtp:
	(cd deps/gen_smtp && $(MAKE) ebins)

deps_mochiweb:
	test -d deps/mochiweb/ebin || mkdir deps/mochiweb/ebin
	(cd deps/mochiweb; $(MAKE))

deps_erlwsh:
	(cd deps/erlwsh; $(MAKE))

deps_all: deps_smtp deps_mochiweb deps_erlwsh

docs:
	priv/erldocs $(DOC_DIR)

ebins: src/ns_server.app.src
	$(REBAR) compile

src/ns_server.app.src: src/ns_server.app.src.in $(TMP_VER)
	(sed s/0.0.0/'$(if $(MEMBASE_VERSION),$(MEMBASE_VERSION),$(shell cat $(TMP_VER)))'/g $< > $@) || (rm $@ && false)

ifdef MEMBASE_VERSION
.PHONY: src/ns_server.app.src
endif

priv/public/js/all-images.js: priv/public/images priv/public/images/spinner scripts/build-all-images.rb
	ruby scripts/build-all-images.rb >$@ || (rm $@ && false)

$(TMP_VER):
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

REST_PREFIX := $(PREFIX)
NS_SERVER := $(PREFIX)/ns_server

install: all $(TMP_VER) fail-unless-configured
	$(MAKE) do-install "NS_SERVER_VER=$(strip $(shell cat $(TMP_VER)))" "PREFIX=$(strip $(shell . `pwd`/.configuration && echo $$prefix))"

ifdef NS_SERVER_VER

ifeq (,$(PREFIX))
$(error "need PREFIX defined")
endif

NS_SERVER_LIBDIR := $(PREFIX)/lib/ns_server/erlang/lib/ns_server-$(NS_SERVER_VER)
ERLWSH_LIBDIR := $(PREFIX)/lib/ns_server/erlang/lib/erlwsh
GEN_SMTP_LIBDIR := $(PREFIX)/lib/ns_server/erlang/lib/gen_smtp
MOCHIWEB_LIBDIR := $(PREFIX)/lib/ns_server/erlang/lib/mochiweb

do-install:
	echo $(PREFIX)
	mkdir -p $(NS_SERVER_LIBDIR)
	cp -r ebin $(NS_SERVER_LIBDIR)/
	mkdir -p $(NS_SERVER_LIBDIR)/priv
	cp -r priv/public $(NS_SERVER_LIBDIR)/priv/
	mkdir -p $(ERLWSH_LIBDIR)
	cp -r deps/erlwsh/ebin $(ERLWSH_LIBDIR)/
	cp -r deps/erlwsh/priv $(ERLWSH_LIBDIR)/
	@true mkdir -p $(GEN_SMTP_LIBDIR)
	@true cp -r deps/gen_smtp/ebin $(GEN_SMTP_LIBDIR)/
	mkdir -p $(MOCHIWEB_LIBDIR)
	cp -r deps/mochiweb/ebin $(MOCHIWEB_LIBDIR)/
	mkdir -p $(PREFIX)/etc/membase
	sed -e 's|@PREFIX@|$(PREFIX)|g' <etc/static_config.in >$(PREFIX)/etc/membase/static_config
	touch $(PREFIX)/etc/membase/config
	mkdir -p $(PREFIX)/bin/
	sed -e 's|@PREFIX@|$(PREFIX)|g' <membase-server.sh.in >$(PREFIX)/bin/membase-server
	sed -e 's|@PREFIX@|$(PREFIX)|g' <mbbrowse_logs.in >$(PREFIX)/bin/mbbrowse_logs
	cp mbcollect_info $(PREFIX)/bin/mbcollect_info
	chmod +x $(PREFIX)/bin/membase-server $(PREFIX)/bin/mbbrowse_logs $(PREFIX)/bin/mbcollect_info
	mkdir -p $(PREFIX)/var/lib/membase/mnesia
	mkdir -p $(PREFIX)/var/lib/membase/logs
	cp priv/init.sql $(PREFIX)/etc/membase/
	cp ebucketmigrator $(PREFIX)/bin/ebucketmigrator
	chmod +x $(PREFIX)/bin/ebucketmigrator

endif

clean clean_all:
	@(cd deps/gen_smtp && $(MAKE) clean)
	@(cd deps/mochiweb && $(MAKE) clean)
	@(cd deps/erlwsh && $(MAKE) clean)
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

$(NS_SERVER_PLT):
	dialyzer --output_plt $@ --build_plt -pa ebin --apps compiler crypto erts inets kernel mnesia os_mon sasl ssl stdlib xmerl -c deps/mochiweb/ebin deps/erlwsh/ebin

dialyzer: all $(NS_SERVER_PLT)
	dialyzer --plt $(NS_SERVER_PLT) -pa ebin -c ebin

dialyzer_obsessive: all $(NS_SERVER_PLT)
	dialyzer --plt $(NS_SERVER_PLT) -Wunmatched_returns -Werror_handling -Wrace_conditions -Wbehaviours -Wunderspecs -pa ebin -c ebin

dialyzer_rebar: all
	$(REBAR) analyze

Features/Makefile:
	(cd features && ../test/parallellize_features.rb) >features/Makefile

.PHONY : features/Makefile

parallel_cucumber: features/Makefile
	$(MAKE) -k -C features all_branches

ebucketmigrator: ebins deps_all
	erl -noshell -noinput -pa ebin -s misc build_ebucketmigrator -s init stop
