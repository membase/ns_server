#!/bin/sh
# Copyright (c) 2010, NorthScale, Inc.
# All rights reserved.
cd `dirname $0`
exec erl -pa `find . -type d -name ebin` -name $1 -boot start_sasl -setcookie nocookie -eval 'application:start(ns_server).' $2 $3 $4 $5 $6 $7
