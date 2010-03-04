#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
exec erl -boot start_sasl -noshell -eval 'rb:start([{report_dir, "logs"}]), rb:show(), halt(0).'
