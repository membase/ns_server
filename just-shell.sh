#!/bin/sh
cd `dirname $0`
exec erl -pa `find . -type d -name ebin` -boot start_sasl
