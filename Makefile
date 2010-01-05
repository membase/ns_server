SHELL=/bin/sh

EFLAGS=-pa ebin

TMP_DIR=./tmp

TMP_VER=$(TMP_DIR)/version_num.tmp

.PHONY: ebins

all: ebins test deps_all

deps_all:
	$(MAKE) -C deps/Menelaus all

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make
	cp src/*.app ebin

clean:
	rm -f $(TMP_VER)
	rm -f $(TMP_DIR)/*.cov.html
	rm -f cov.html
	rm -f erl_crash.dump
	rm -f ns_server_*.tar.gz
	rm -rf test/log
	rm -rf ebin

bdist: clean ebins
	git describe | sed s/-/_/g > $(TMP_VER)
	tar --directory=.. -czf ns_server_`cat $(TMP_VER)`.tar.gz ns_server/ebin
	echo created ns_server_`cat $(TMP_VER)`.tar.gz

test: test_unit

test_unit: ebins
	erl $(EFLAGS) -noshell -s ns_server_test test -s init stop -kernel error_logger silent

dialyzer: ebins
	dialyzer -pa ebin -r .

