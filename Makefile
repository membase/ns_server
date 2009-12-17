TMP_DIR=./tmp
TMP_VER=$(TMP_DIR)/version_num.tmp
DIST_DIR=$(TMP_DIR)/menelaus

all: menelaus_server

menelaus_server:
	(cd menelaus_server; $(MAKE))

clean:
	(cd menelaus_server; $(MAKE) clean)
	rm -f menelaus_*.tar.gz
	rm -f $(TMP_VER)
	rm -rf $(DIST_DIR)

dist: clean all
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	test -d $(DIST_DIR) || mkdir $(DIST_DIR)
	test -d $(DIST_DIR)/deps || mkdir $(DIST_DIR)/deps
	test -d $(DIST_DIR)/deps/menelaus || mkdir $(DIST_DIR)/deps/menelaus
	git describe | sed s/-/_/g > $(TMP_VER)
	cp -R public $(DIST_DIR)
	cp -R menelaus_server/ebin $(DIST_DIR)/deps/menelaus
	cp -R menelaus_server/deps/mochiweb-src $(DIST_DIR)/deps/mochiweb
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus/deps menelaus/public
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: menelaus_server
