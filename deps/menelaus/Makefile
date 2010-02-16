# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
TMP_DIR=./tmp
TMP_VER=$(TMP_DIR)/version_num.tmp
DIST_DIR=$(TMP_DIR)/menelaus
SPROCKETIZE=`which sprocketize`

.PHONY: ebins ebin_app version

all: deps priv/public/js/all.js priv/public/js/t-all.js ebins

ebins: ebin_app
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make

ebin_app: version
	test -d ebin || mkdir ebin
	sed s/0.0.0/`cat $(TMP_VER)`/g src/menelaus.app.src > ebin/menelaus.app

version:
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	git describe | sed s/-/_/g > $(TMP_VER)

priv/public/js/all.js: priv/js/*.js
	mkdir -p `dirname $@`
	$(SPROCKETIZE) -I priv/js priv/js/app.js >$@

priv/public/js/t-all.js: priv/js/*.js
	mkdir -p `dirname $@`
	$(SPROCKETIZE) -I priv/js priv/js/app.js priv/js/hooks.js >$@

deps:
	$(MAKE) -C deps/mochiweb

clean:
	-rm -f ebin/*
	$(MAKE) -C deps/mochiweb clean
	rm -f menelaus_*.tar.gz priv/public/js/t-all.js priv/public/js/all.js
	rm -f $(TMP_VER)
	rm -rf $(DIST_DIR)
	rm -f TAGS

# assuming exuberant-ctags
TAGS:
	ctags -eR .

# TODO: somehow fix dependency on ns_server's ns_log at least in tests
test: all
	erl -noshell -pa ./ebin ./deps/*/ebin -boot start_sasl -s menelaus_web test -s menelaus_util test -s menelaus_stats test -s init stop

bdist: clean all
	test -d $(DIST_DIR)/deps/menelaus/priv || mkdir -p $(DIST_DIR)/deps/menelaus/priv
	cp -R ebin $(DIST_DIR)/deps/menelaus
	cp -R priv/public $(DIST_DIR)/deps/menelaus/priv/public
	cp -R deps/mochiweb $(DIST_DIR)/deps/mochiweb
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: deps bdist clean TAGS
