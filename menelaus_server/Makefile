all: deps
	(cd src;$(MAKE))

deps:
	$(MAKE) -C deps/mochiweb-src

clean:
	(cd src;$(MAKE) clean)

test: all
	erl -noshell -pa ./ebin ./deps/*/ebin -boot start_sasl -s menelaus_server_web test -s init stop

.PHONY: deps
