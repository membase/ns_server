#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
exec erl -pa `find . -type d -name ebin` -boot start_sasl
