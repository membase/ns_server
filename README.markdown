# emoxi

This is the 'smart service' part of the NorthScale Server.

Originally forked from ememcached.

## Quick Start

The basic idea is that there will be one server that understands
commands and can issue responses.  A sample implementation is provided
that uses an in-memory hash table per session.  You can try it out
like this:

    erl -pa ebin -s mc_server_ascii_dict main

Then connect to port 11222 with your favorite memcached binary
protocol client.

## Slow Start

So you want to write your own backend?  No problem.  Take a look at
`mc_server_ascii_dict` for an example backend that implements a few
ascii protocol commands.

## License

MPL - We made this for you!

## TODO

- Add MPL headers to each file.