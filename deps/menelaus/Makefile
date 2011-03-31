# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
TMP_DIR=./tmp
TMP_VER=$(TMP_DIR)/version_num.tmp
DIST_DIR=$(TMP_DIR)/menelaus
SPROCKETIZE=sprocketize
REBAR=../../rebar

.PHONY: ebins version

# always rebuild TMP_VER just in case someone depends on it be
# up-to-date
.PHONY: $(TMP_VER)

all: deps

$(TMP_VER):
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	(git describe | sed s/-/_/g > $(TMP_VER)) || (rm $@ && false)

deps:
	test -d deps/mochiweb/ebin || mkdir deps/mochiweb/ebin
	(cd deps/mochiweb; $(MAKE))
	(cd deps/erlwsh; $(MAKE))

clean:
	-rm -f ebin/*
	@(cd deps/mochiweb; $(MAKE) clean)
	rm -f menelaus_*.tar.gz
	@(cd deps/erlwsh; $(MAKE) clean)
	rm -f $(TMP_VER)
	rm -rf $(DIST_DIR)
	rm -f TAGS

test: all
	erl -pa ../../ebin ./ebin ./deps/*/ebin -noshell -s t start -s init stop -kernel error_logger silent

bdist: clean all
	test -d $(DIST_DIR)/deps/menelaus/priv || mkdir -p $(DIST_DIR)/deps/menelaus/priv
	cp -R priv/public $(DIST_DIR)/deps/menelaus/priv/public
	cp -R deps/mochiweb $(DIST_DIR)/deps/mochiweb
	cp -R deps/erlwsh $(DIST_DIR)/deps/erlwsh
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: deps bdist clean TAGS
