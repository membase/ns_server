# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
TMP_DIR=./tmp
TMP_VER=$(TMP_DIR)/version_num.tmp
DIST_DIR=$(TMP_DIR)/menelaus

all: deps priv/public/js/all.js priv/public/js/t-all.js
	(cd src;$(MAKE))

priv/public/js/all.js: priv/js/*.js
	mkdir -p `dirname $@`
	sprocketize -I priv/js priv/js/app.js >$@

priv/public/js/t-all.js: priv/js/*.js
	mkdir -p `dirname $@`
	sprocketize -I priv/js priv/js/app.js priv/js/hooks.js >$@

deps:
	$(MAKE) -C deps/mochiweb-src

clean:
	$(MAKE) -C src clean
	$(MAKE) -C deps/mochiweb-src clean
	rm -f menelaus_*.tar.gz
	rm -f $(TMP_VER)
	rm -rf $(DIST_DIR)

# TODO: somehow fix dependency on ns_server's ns_log at least in tests
test: all
	erl -noshell -pa ./ebin ./deps/*/ebin -boot start_sasl -s menelaus_web test -s init stop
	erl -noshell -pa ./ebin ./deps/*/ebin ../../ebin -boot start_sasl -s stats_aggregator_manager test -s init stop

bdist: clean all
	test -d $(DIST_DIR)/deps/menelaus/priv || mkdir -p $(DIST_DIR)/deps/menelaus/priv
	git describe | sed s/-/_/g > $(TMP_VER)
	cp -R ebin $(DIST_DIR)/deps/menelaus
	cp -R priv/public $(DIST_DIR)/deps/menelaus/priv/public
	cp -R deps/mochiweb-src $(DIST_DIR)/deps/mochiweb
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: deps bdist clean
