#! /bin/sh -
exec erl -pa $PWD/ebin $PWD/deps/*/ebin -boot start_sasl -s erlwsh
