# emoxi

A walkthrough of the design and key files in the emoxi system...

## Erlang Notes

We depend on gen_tcp and using tcp sockets in 'passive' mode.  That
means tcp messages are not integerated into the erlang
process/messagebox system, and we are doing explicit, e-process
"blocking" calls to send and receive messages.  We use multiple erlang
processes for asynchronicity and concurrency.

The term "e-process" and "e-port" are used to clarify when we're
talking abouterlang processes (as opposed to OS processes).

## Protocol Utilities

    mc_ascii.erl
    mc_binary.erl

These lowest level utility modules help parse, encode/decode packets,
and also do e-process blocking send/recv calls against a socket.

# The Client Side

## Client API

    mc_client_ascii.erl
    mc_client_binary.erl

The above two clients modules present a client-side API, speaking
ascii and binary protocol, respectively.  The API is not end-user
friendly, but is instead proxy-friendly, in that the API is very
regular...

    cmd(Opcode, Sock, RecvCallback, Args).

For mc_client_ascii, the Opcode is an atom, like get, set, delete.
For mc_client_binary, the Opcode is a macro constant from
include/mc_constants.hrl, like ?GET, ?SET, ?DELETE.

For commands that return multiple results, such as get or stats, the
RecvCallback callback function will be invoked zero or more times.

The Args are protocol-specific.

## Client API-Conversion (ac) Layer

    mc_client_ascii_ac.erl
    mc_client_binary_ac.erl

The API conversion layers provide a facade over the Client API's, so
that a the proxy can send an ascii message to a binary server (and
vice-versa).  Again, the API here is very regular...

    cmd(Opcode, Sock, RecvCallback, Args).

For example, if you made an ascii-style API call on the
mc_client_binary_ac...

    mc_client_binary_ac:cmd(get, SocketToBinaryServer, RecvCallback,
                            ["many", "multiget", "keys"]).

The mc_client_binary_ac implementation will convert that into 3 binary
GETKQ calls and a NOOP call.

# The Server Side

## The Listen/Accept Loop

    mc_accept.erl

This module opens up a listening port and spawns child e-processes to
manage each client connection (or session).  Each client connection gets two child e-processes, which are paired: one child-process to receive incoming messages, and another child-e-process to do sends of responses.

The mc_accept module is genericized so that different server
implementation modules can be plugged in to provide different
behavior.  There are two kinds of implementation modules: protocol
modules and processor modules.

## Protocol Modules

    mc_server_ascii.erl
    mc_server_binary.erl
    mc_server_detect.erl

A protocol module, when coupled into a listen/accept loop, knows how
to receive messages on a particular protocol, and invoke a plugged-in
processor module when a message is fully received.

A special protocol module, mc_server_detect, reads the 1st byte, and
delegates future protocol handling to either mc_server_ascii or
mc_server_binary depending on the client's actual protocol usage.

## Processor Modules

    mc_server_ascii_dict.erl
    mc_server_ascii_proxy.erl
    mc_server_binary_proxy.erl

The mc_server_ascii_dict is a sample processor module that implements
a dictionary/hashmap per session, as a memcached ascii server.

The mc_server_ascii_proxy processor allows ascii clients to proxy to
either ascii or binary downstream servers.

The mc_server_binary_proxy processor allows binary clients to proxy to
either ascii or binary downstream servers.  (Note, as of Reveal 1.0,
the binary-client to ascii-server proxying is incomplete.)
