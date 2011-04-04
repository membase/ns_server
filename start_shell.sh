#!/bin/sh
# Copyright (c) 2011, Membase, Inc.
# All rights reserved.
basedir=${0%%${0##*/}}
cd "$basedir"

test -f "$basedir/.configuration" || (echo "run ./configure and make first!" && false) || exit 1

. "$basedir/.configuration"

if test -z "$prefix" ; then
    echo "configuration is damaged somehow. Re-running ./configure might help"
    exit 1
fi

mkdir logs > /dev/null 2>&1
mkdir -p "data/ns_0/mnesia" >/dev/null 2>&1

# Initialize distributed erlang on the system (i.e. epmd)
if [ -z "$DONT_START_EPMD" ]; then
  erl -noshell -setcookie nocookie -sname init -run init stop 2>&1 > /dev/null
fi

./scripts/mkcouch.sh n_0 9500

exec erl \
    +A 16 \
    -pa `find "${prefix}/lib/couchdb/erlang/lib" -type d -name ebin` \
    -pa `find . -type d -name ebin` \
    -setcookie nocookie \
    -run ns_bootstrap \
    -couch_ini "${prefix}/etc/couchdb/default.ini" couch/n_0_conf.ini \
    -ns_server error_logger_mf_dir '"logs"' \
    -ns_server error_logger_mf_maxbytes 10485760 \
    -ns_server error_logger_mf_maxfiles 10 \
    -ns_server dont_suppress_stderr_logger true \
    -ns_server config_path '"./etc/static_config.in"' \
    -ns_server path_config_etcdir '"priv"' \
    -ns_server path_config_bindir "\"${prefix}/bin\"" \
    -ns_server path_config_libdir "\"${prefix}/lib\"" \
    -ns_server path_config_datadir "\"data/ns_0\"" \
    -ns_server path_config_tmpdir "\"tmp\"" \
    -kernel inet_dist_listen_min 21100 inet_dist_listen_max 21199 \
    -- "$@"
