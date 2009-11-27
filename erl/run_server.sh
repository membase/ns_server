#!/bin/sh

cd `dirname $0`
make
erl -noshell -pa ebin deps/*/ebin -run rest_server start_link 80
