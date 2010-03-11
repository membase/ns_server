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
    -sasl sasl_error_logger false \
    -sasl error_logger_mf_dir '"logs"' \
    -sasl error_logger_mf_maxbytes 10485760 \
    -sasl error_logger_mf_maxfiles 10 \
    -kernel inet_dist_listen_min 21100 inet_dist_listen_max 21199 \
    -- "$@"
