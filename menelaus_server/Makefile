TMP_VER=version_num.tmp

all: deps
	(cd src;$(MAKE))

deps:
	$(MAKE) -C deps/mochiweb-src

clean:
	(cd src;$(MAKE) clean)
	rm -f $(TMP_VER)

test: all
	erl -noshell -pa ./ebin ./deps/*/ebin -boot start_sasl -s menelaus_server_web test -s init stop

.PHONY: deps

dist: clean all
	git describe | sed s/-/_/g > $(TMP_VER)
	cp deps/*/ebin/* ebin
	tar --directory=.. -czf menelaus_server_`cat $(TMP_VER)`.tar.gz ./menelaus_server/ebin
	echo created menelaus_server_`cat $(TMP_VER)`.tar.gz

