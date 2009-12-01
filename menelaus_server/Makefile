all: deps
	(cd src;$(MAKE))

deps:
	$(MAKE) -C deps/mochiweb-src

clean:
	(cd src;$(MAKE) clean)

.PHONY: deps
