# emoxi

This is the memcached-protocol router part of the NorthScale Server.

Originally forked from ememcached.

## Dependencies

For development, this emoxi directory should be a sibling directory to
the ns_server directory from the github.com/northscale/ns_server
project.  This Makefile assumes this directory configuration.

## Quick Start

You'll need erlang, of course.

To do a build, do...

    make

To run unit tests, do...

    make test

A sample implementation is provided that uses an in-memory hash table
per session.  You can try it out like this:

    erl -pa ebin -s mc_server_ascii_dict main

Then connect to port 11222 with your favorite memcached ascii
protocol client, like telnet.

## Slow Start

So you want to write your own backend?  No problem.  Take a look at
`mc_server_ascii_dict` for an example backend that implements a few
ascii protocol commands.

To run all the proxy variations on different ports (see
src/mc_test.erl), do...

    erl -pa ebin -s mc_test main

## License

Still under consideration, though MPL is the likely candidate.  For now,
all rights are reserved.

## TODO

- Add license as needed.

Copyright (c) 2010, NorthScale, Inc.
