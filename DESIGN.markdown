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

These lowest level utility modules help parse, encode/decode packets.
Thare are also functions to make synchronous, (e-process) blocking
send/recv calls against a tcp socket.

# The Client Side

## Client API

    mc_client_ascii.erl
    mc_client_binary.erl

The above two clients modules present client-side API's, speaking
ascii and binary protocol, respectively.  The API is not end-user
friendly, but is instead proxy-friendly, in that the API is very
normalized and regular...

    cmd(Opcode, Sock, RecvCallback, Args).

For example...

    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    {ok, Result} = mc_client_ascii:cmd(delete, Sock, undefined,
                                       #mc_entry{key = <<"aaa">>}),
    ok = gen_tcp:close(Sock).

For mc_client_ascii, the Opcode is an atom, like get, set, delete.
For mc_client_binary, the Opcode is a macro constant from
include/mc_constants.hrl, like ?GET, ?SET, ?DELETE.

For commands that return multiple results, such as get or stats, the
RecvCallback callback function will be invoked zero or more times.

The Args are protocol-specific.

## The Entry Record

The mc_entry record (equivalent to a struct) represents a catch-all
key-value pair, and is used regularly throughout the codebase.  For
the binary protocol, an additional mc_header record/struct is used to
hold binary header-specific information.

The definitions of these records are in the include/*.hrl files.

## Client API-Conversion (ac) Layer

    mc_client_ascii_ac.erl
    mc_client_binary_ac.erl

The API conversion (or "ac") layers provide a facade over the
previously described Client API's, so that a the proxy can send an
ascii message to a binary server (and vice-versa).  The ac API
here is very regular, and is exactly the same as the normal Client
API's...

    cmd(Opcode, Sock, RecvCallback, Args).

For example, if you made an ascii-style API call on the
mc_client_binary_ac...

    mc_client_binary_ac:cmd(get, SocketToBinaryServer, RecvCallback,
                            ["many", "multiget", "keys"]).

...then the mc_client_binary_ac implementation will convert that
single call into into 3 binary GETKQ calls and a NOOP call.

# The Server Side

## The Listen/Accept Loop

    mc_accept.erl

This module opens up a listening port and spawns child e-processes to
manage each client connection (or session).  Each client connection
gets two child e-processes, which are paired: one child-process to
receive incoming messages, and another child-e-process to do sends of
responses.

The mc_accept module is genericized so that different server
implementation modules can be plugged in to provide different
behavior.  There are two kinds of pluggable implementation modules:
protocol modules and processor modules.

## Protocol Modules

    mc_server_ascii.erl
    mc_server_binary.erl
    mc_server_detect.erl

A protocol module, when coupled into the previously described
listen/accept loop modules, knows how to receive messages on a
particular protocol, and invoke a pluggable processor module when a
message is fully received.

A special protocol module, mc_server_detect, reads the 1st byte, and
delegates future protocol handling to either the mc_server_ascii or
mc_server_binary protocol modules.

## A Sample Processor Module

    mc_server_ascii_dict.erl

The mc_server_ascii_dict is a sample, pluggable processor module that
implements a local, in-memory dictionary/hashmap per client session.
It only implements a subset of simple simple memcached ascii procotol
commands.

## Proxy Processor Modules

    mc_server_ascii_proxy.erl
    mc_server_binary_proxy.erl

The mc_server_XXX_proxy modules receive protocol-specific messages and
forward those (potentially replicated) messages onwards to downstream
servers.  During the forwarding, the client session/connection
handling e-process is blocked.  That is, each message from an upstream
client is processed synchronously.

The mc_server_ascii_proxy processor allows ascii-protocol clients to
proxy to either ascii or binary downstream servers, with possible
replication.

The mc_server_binary_proxy processor allows binary-protocol clients to
proxy to either ascii or binary downstream servers, with possible
replication.  (Note, as of Reveal 1.0, the binary-client to
ascii-server proxying is incomplete.)

To mc_server_XXX_proxy processors always call the replication module
for message forwarding.

## Replication

The mc_replication.erl module is a gen_server e-process that manages
replication state and the W+R>N algorithm.  If no replication is
needed (number of replicas (or N) == 1, for example), then, the
replication module just forwards the message to the downstream
manager, which is described next.

If replication is needed (N > 1), the replication module creates
state-tracking data and forwards multiple messages to the downstream
manager as necessary.

Instead of spawning a separate e-process for each replication
situation, by instead using the state-tracking data, we have only one
replication e-process/gen_server for the entire erlang VM, no matter
how many replication requests are concurrently in-flight.

When the replication of a request has reached an W+R>N quorum safety
point, the replication module notifies the replication invoker (the
client session/connection e-process).  The replication invoker, for
example, can then proceed to respond to the upstream client and
process more client messages.

## Downstream Manager

The downstream manager (mc_downstream.erl) is another
e-process/gen_server that manages a set of downstream connections.
Each downstream connection has its own spawned and linked e-process.
These child e-processes each manage an individual tcp
socket/connection to a memcached server and use the appropriate
mc_client_XXX module to send/receive messages on that socket.

The downstream manager is unaware of pool or bucket concepts, but has
enough monitoring features to allow higher layers of the system to be
notified when a downstream connection goes down.

## Pool & Bucket

A pool is a container of memcached server addreses and of buckets.

## Address

A memcached server address includes (at least) hostname, port, and
protocol.  Other parts of an address might include weight and
auth/cred information.

