-module(mc_bucket).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% API for buckets.

%% TODO: A proper implementation.
%% TODO: Consider replacing implementation with gen_server.

% Callers should consider the returned value to be opaque.
% One day, the return value, for example, might be changed
% into a gen_server Pid.
create(BucketId, BucketAddrs) ->
    #mc_bucket{id = BucketId, addrs = BucketAddrs}.

id(#mc_bucket{id = Id})          -> Id.
addrs(#mc_bucket{addrs = Addrs}) -> Addrs.

% Choose the Addr that should contain the Key.
choose_addr(#mc_bucket{addrs = Addrs}, Key) ->
    % TODO: A proper consistent hashing.
    {Key, hd(Addrs)}.

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The result Addr's list might
% have length <= N.
choose_addrs(#mc_bucket{addrs = Addrs}, Key, N) ->
    % TODO: A proper consistent hashing.
    {Key, lists:sublist(Addrs, N)}.

% ------------------------------------------------

choose_addr_test() ->
    B1 = create(buck1, [a1]),
    ?assertMatch({key1, a1}, choose_addr(B1, key1)),
    ?assertMatch({key2, a1}, choose_addr(B1, key2)),
    ok.

choose_addrs_test() ->
    B1 = create(buck1, [a1]),
    ?assertMatch({key5, [a1]}, choose_addrs(B1, key5, 1)),
    ?assertMatch({key6, [a1]}, choose_addrs(B1, key6, 1)),
    ok.

choose_addr_str_test() ->
    B1 = create(buck1, [a1]),
    ?assertMatch({"key1", a1}, choose_addr(B1, "key1")),
    ?assertMatch({"key2", a1}, choose_addr(B1, "key2")),
    ok.

choose_addrs_str_test() ->
    B1 = create(buck1, [a1]),
    ?assertMatch({"key5", [a1]}, choose_addrs(B1, "key5", 1)),
    ?assertMatch({"key6", [a1]}, choose_addrs(B1, "key6", 1)),
    ok.

