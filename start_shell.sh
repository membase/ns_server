#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
mkdir logs > /dev/null 2>&1

# Initialize distributed erlang on the system (i.e. epmd)
erl -noshell -setcookie nocookie -sname init -run init stop 2>&1 > /dev/null

exec erl -pa `find . -type d -name ebin` \
    -setcookie nocookie \
    -run ns_bootstrap \
    -config priv/erlang_app -- "$@"
