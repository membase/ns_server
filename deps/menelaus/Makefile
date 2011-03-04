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

all: deps priv/public/js/all.js ebins

ebins: src/menelaus.app.src
	test -d ebin || mkdir ebin
	$(REBAR) compile

src/menelaus.app.src: src/menelaus.app.src.in $(TMP_VER)
	(sed s/0.0.0/`cat $(TMP_VER)`/g $< > $@) || (rm $@ && false)

$(TMP_VER):
	test -d $(TMP_DIR) || mkdir $(TMP_DIR)
	(git describe | sed s/-/_/g > $(TMP_VER)) || (rm $@ && false)

priv/public/js/dev/all-images.js: priv/public/images priv/public/images/spinner build-all-images.rb
	ruby build-all-images.rb >$@ || (rm $@ && false)

priv/public/js/all.js: priv/public/js/dev/*.js priv/public/js/dev/all-images.js
	mkdir -p `dirname $@`
	$(SPROCKETIZE) -I priv/public/js/dev priv/public/js/dev/app.js >$@ || (rm $@ && false)

priv/public/js/t-all.js: priv/public/js/dev/*.js priv/public/js/dev/all-images.js
	mkdir -p `dirname $@`
	$(SPROCKETIZE) -I priv/public/js/dev priv/public/js/dev/app.js priv/public/js/dev/hooks.js >$@ || (rm $@ && false)

deps:
	(cd deps/erlwsh; $(MAKE))

clean:
	-rm -f ebin/*
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
	cp -R deps/erlwsh $(DIST_DIR)/deps/erlwsh
	tar --directory=$(TMP_DIR) -czf menelaus_`cat $(TMP_VER)`.tar.gz menelaus
	echo created menelaus_`cat $(TMP_VER)`.tar.gz

.PHONY: deps bdist clean TAGS
