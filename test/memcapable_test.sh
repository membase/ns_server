# Copyright (c) 2009, NorthScale, Inc.
# All rights reserved.
MEMCAPABLE_PATH=/usr/local/bin/memcapable
MEMCACHED_PATH=/usr/local/bin/memcached
EBINS=./ebin
EMOXI_PORT=11255
EMOXI_HOST=127.0.0.1
EFLAGS="-noshell"
PIDS="";
ERL="erl"

if [ ! -x "`which $ERL`" ]; then
    ERL="/usr/local/bin/erl"
fi

#############
addPid () { #
#############
	new_pid=$1
	if [ -z "${PIDS}" ]; then
		PIDS="${new_pid}"
	else
		PIDS="${PIDS} ${new_pid}"
	fi
}

##########
die () { #
##########
	rc=$1; shift
	if [ $# -ge 1 ]; then
		msg=$*;
		echo "${msg}"
	fi
	exit "${rc}"
}

########
# main #
########

while getopts c:m:e:p:h:f:b:d: cur_opt; do
	case "${cur_opt}" in
		c) MEMCAPABLE_PATH="${OPTARG}";;
		m) MEMCACHED_PATH="${OPTARG}";;
		e) ERL="${OPTARG}";;
		p) EMOXI_PORT="${OPTARG}";;
		h) EMOXI_HOST="${OPTARG}";;
		f) EFLAGS="${OPTARG}";;
		b) EBINS="${OPTARG}";;
		d) OUT_DIR="${OPTARG}";;
		?) die 1;;
        *) die 1 "unrecognized option ${cur_opt}";;
	esac
done

if [ ! -x "${MEMCAPABLE_PATH}" ]; then
	die 1 "Memcapable path, ${MEMCAPABLE_PATH}, does not point to an executable memcapable binary"
fi

if [ ! -x "${MEMCACHED_PATH}" ]; then
	die 1 "Memcached path, ${MEMCACHED_PATH}, does not point to an executable memcached binary"
fi

ERL_ORIGINAL="$ERL"
ERL=`which "$ERL"`

if [ ! -x "${ERL}" ]; then
	die 1 "Erlang path, ${ERL_ORIGINAL}, does not point to an executable binary"
fi

if [ -z "${OUT_DIR}" ]; then
	die 1 "You must specify the path to the output directory"
fi

if [ ! -d "${OUT_DIR}" ]  || [ ! -w "${OUT_DIR}" ]; then
	die 1 "The specified output directory path does not point to a writeable directory"
fi

${MEMCACHED_PATH} > ${OUT_DIR}/memcapable_mc.out 2>&1 &
addPid $!

${ERL} -pa ${EBINS} ${EFLAGS} -s mc_test main > ${OUT_DIR}/memcapable_emoxi.out 2>&1 &
addPid $!

#Sleep for a bit to let emoxi get its wits about itself
sleep 1

${MEMCAPABLE_PATH} -v -h ${EMOXI_HOST} -p ${EMOXI_PORT}
rc=$?

#Kill procs
for cur_pid in ${PIDS}; do
	if [ -z "${cur_pid}" ]; then
		break;
	fi
	kill "${cur_pid}"
done

exit "${rc}"
