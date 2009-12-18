SHELL=/bin/sh

EFLAGS=-pa ebin

TMP_VER=version_num.tmp

.PHONY: ebins

all: ebins

ebins:
	test -d ebin || mkdir ebin
	erl $(EFLAGS) -make
	cp src/ns_server_app.app ebin

clean:
	rm -f cov.html erl_crash.dump
	rm -rf ebin

bdist: clean ebins
	git describe | sed s/-/_/g > $(TMP_VER)
	tar --directory=.. -czf ns_server_sup_`cat $(TMP_VER)`.tar.gz ns_server_sup/ebin
	echo created ns_server_sup_`cat $(TMP_VER)`.tar.gz

