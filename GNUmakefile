# Copyright (c) 2011, Couchbase, Inc.
# All rights reserved.

# Note: This Makefile is provided as a convenience wrapper to CMake,
# which is the build tool used for configuring this project. Please do
# not make any substantive changes only in this file or in the
# top-level "configure" script, as the normal process of building
# Couchbase server uses only CMake.

SHELL=/bin/sh

ifneq (,$(wildcard build))
all:
	cd build && $(MAKE) --no-print-directory all

fail-unless-configured:
	@true

else
all fail-unless-configured:
	@echo
	@echo "you need to run ./configure with --prefix option to be able to run ns_server"
	@echo
	@false
endif


.PHONY: test docs

clean clean_all:
	cd build && $(MAKE) --no-print-directory clean ns_realclean

install:
	cd build && $(MAKE) --no-print-directory $@

dataclean distclean test docs dialyzer dialyzer_obsessive:
	cd build && $(MAKE) --no-print-directory ns_$@

# assuming exuberant-ctags
TAGS:
	ctags -eR .




# Targets from this point on are NOT currently replicated with CMake, so
# this GNUmakefile remains the only way to invoke them. Ideally at some
# point this should be rectified. TODO


prebuild_vbmap:
	cd deps/vbmap && GOOS=linux GOARCH=386 go build -ldflags "-B 0x$$(sed -e 's/-//g' /proc/sys/kernel/random/uuid)" -o ../../priv/i386-linux-vbmap
	cd deps/vbmap && GOOS=darwin GOARCH=386 go build -o ../../priv/i386-darwin-vbmap
	cd deps/vbmap && GOOS=windows GOARCH=386 go build -o ../../priv/i386-win32-vbmap.exe

prebuild_generate_cert:
	cd deps/generate_cert && GOOS=linux GOARCH=386 go build -ldflags "-B 0x$$(sed -e 's/-//g' /proc/sys/kernel/random/uuid)" -o ../../priv/i386-linux-generate_cert
	cd deps/generate_cert && GOOS=darwin GOARCH=386 go build -o ../../priv/i386-darwin-generate_cert
	cd deps/generate_cert && GOOS=windows GOARCH=386 go build -o ../../priv/i386-win32-generate_cert.exe

prebuild_gozip:
	cd deps/gozip && GOOS=linux GOARCH=386 go build -ldflags "-B 0x$$(sed -e 's/-//g' /proc/sys/kernel/random/uuid)" -o ../../priv/i386-linux-gozip
	cd deps/gozip && GOOS=darwin GOARCH=386 go build -o ../../priv/i386-darwin-gozip
	cd deps/gozip && GOOS=windows GOARCH=386 go build -o ../../priv/i386-win32-gozip.exe

prebuild_goport:
	cd deps/goport && GOOS=linux GOARCH=386 go build -ldflags "-B 0x$$(sed -e 's/-//g' /proc/sys/kernel/random/uuid)" -o ../../priv/i386-linux-goport
	cd deps/goport && GOOS=darwin GOARCH=386 go build -o ../../priv/i386-darwin-goport
	cd deps/goport && GOOS=windows GOARCH=386 go build -o ../../priv/i386-win32-goport.exe
