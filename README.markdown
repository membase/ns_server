# ememcached

This is a toolkit for building memcached servers in erlang using the
memcached binary protocol.

## Quick Start

The basic idea is that there will be one server that understands
commands and can issue responses.  A sample implementation is provided
that uses an in-memory hash table.  You can try it out like this:

    1> {ok, S} = mc_handler_hashtable:start_link().
    {ok,<0.34.0>}
    2> mc_tcp_listener:start_link(11213, S).
    {ok,<0.36.0>}

Then connect to port 11213 with your favorite memcached binary
protocol client.

## Slow Start

So you want to write your own backend?  No problem.  Take a look at
`mc_handler_hashtable` for an example backend implementing
`gen_server` that handles a few commands.

Not all of the commands are defined yet, so there aren't hugely
comprehensive examples, but hopefully there's enough there to get the idea.

## License

MIT or something...  I made this for you!
