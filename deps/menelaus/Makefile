# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
TMP_DIR=./tmp
TMP_VER=$(TMP_DIR)/version_num.tmp
DIST_DIR=$(TMP_DIR)/menelaus
SPROCKETIZE=sprocketize
REBAR=../../rebar

.PHONY: ebins ebin_app version

all: deps priv/public/js/all.js ebins

ebins: ebin_app
	test -d ebin || mkdir ebin
	$(REBAR) compile
#erl -noinput +B $(EFLAGS) -eval 'case make:all() of up_to_date -> halt(0); error -> halt(1) end.'

ebin_app: version
	test -d ebin || mkdir ebin
	sed s/0.0.0/`cat $(TMP_VER)`/g src/menelaus.app.src > ebin/menelaus.app

version:
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

priv/js/all-images.js: priv/public/images priv/public/images/spinner build-all-images.rb
	ruby build-all-images.rb >$@

priv/public/js/all.js: priv/js/*.js priv/js/all-images.js
	mkdir -p `dirname $@`
	$(SPROCKETIZE) -I priv/js priv/js/app.js >$@ || (rm $@ && false)

priv/public/js/t-all.js: priv/js/*.js priv/js/all-images.js
	mkdir -p `dirname $@`
	$(SPROCKETIZE) -I priv/js priv/js/app.js priv/js/hooks.js >$@ || (rm $@ && false)

deps:
	test -d deps/mochiweb/ebin || mkdir deps/mochiweb/ebin
	(cd deps/mochiweb; $(MAKE))
	(cd deps/erlwsh; $(MAKE))

clean:
	-rm -f ebin/*
	@(cd deps/mochiweb; $(MAKE) clean)
	rm -f menelaus_*.tar.gz priv/public/js/t-all.js priv/public/js/all.js
	@(cd deps/erlwsh; $(MAKE) clean)
	rm -f $(TMP_VER)
	rm -rf $(DIST_DIR)
	rm -f TAGS

test: all
	erl -pa ../../ebin ./ebin ./deps/*/ebin -noshell -s t start -s init stop -kernel error_logger silent

bdist: clean all
	test -d $(DIST_DIR)/deps/menelaus/priv || mkdir -p $(DIST_DIR)/deps/menelaus/priv
	cp -R ebin $(DIST_DIR)/deps/menelaus
	cp -R priv/public $(DIST_DIR)/deps/menelaus/priv/public
	cp -R deps/mochiweb $(DIST_DIR)/deps/mochiweb
	cp -R deps/erlwsh $(DIST_DIR)/deps/erlwsh
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: deps bdist clean TAGS
