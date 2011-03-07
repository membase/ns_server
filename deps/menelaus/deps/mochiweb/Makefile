DOC_OPTS={dir,\"doc\"}

all:
	erl -make
	cp src/*.app ebin

edoc:
	$(ERL) -noshell -pa ../ebin \
		-eval "edoc:application(mochiweb), \".\", [$(DOC_OPTS)])" \
		-s init stop


test: all
	$(ERL) -noshell -pa ebin -s mochiweb test -s init stop

clean:
	rm -f ebin/*
