#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
mkdir -p logs
exec erl -pa `find . -type d -name ebin` \
    -setcookie nocookie \
    -run ns_bootstrap \
    -config priv/erlang_app -- "$@"
