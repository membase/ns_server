#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
exec erl -boot start_sasl -noshell -config priv/erlang_app -eval 'rb:start(), rb:grep("'"$1"'"), halt(0).'
