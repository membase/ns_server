#!/bin/sh

echo "see README in build-stuff.sh directory for go cross compilation setup instructions"

cd `dirname $0` || exit $?

export CGO_ENABLED=0

set -x

GOOS=windows GOARCH=386 go build -o ../../priv/i386-win32-godu.exe || exit $?

GOOS=linux GOARCH=386 go build -ldflags "-B 0x$(sed -e 's/-//g' /proc/sys/kernel/random/uuid)" -o ../../priv/i386-linux-godu || exit $?
