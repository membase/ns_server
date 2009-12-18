TMP_DIR=./tmp
TMP_VER=$(TMP_DIR)/version_num.tmp
DIST_DIR=$(TMP_DIR)/menelaus

all: deps
	(cd src;$(MAKE))

deps:
	$(MAKE) -C deps/mochiweb-src

clean:
	$(MAKE) -C src clean
	$(MAKE) -C deps/mochiweb-src clean
	rm -f menelaus_*.tar.gz
	rm -f $(TMP_VER)
	rm -rf $(DIST_DIR)

test: all
	erl -noshell -pa ./ebin ./deps/*/ebin -boot start_sasl -s menelaus_web test -s init stop

bdist: clean all
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	test -d $(DIST_DIR) || mkdir $(DIST_DIR)
	test -d $(DIST_DIR)/deps || mkdir $(DIST_DIR)/deps
	git describe | sed s/-/_/g > $(TMP_VER)
	cp -R priv/public $(DIST_DIR)
	cp -R ebin $(DIST_DIR)/deps/menelaus
	cp -R deps/mochiweb-src $(DIST_DIR)/deps/mochiweb
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus/deps menelaus/public
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: deps bdist clean
