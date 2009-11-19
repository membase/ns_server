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
create(Pool, BucketAddrs, BucketKey) ->
    #mc_bucket{pool = Pool, addrs = BucketAddrs, key = BucketKey}.

% Choose the Addr that should contain the Keys.
% This version is useful for multiget.
choose_addr(Bucket, Keys) when is_list(Keys) ->
    lists:map(fun (Key) -> choose_addr(Bucket, Key) end, Keys);

% Choose the Addr that should contain the Key.
choose_addr(#mc_bucket{addrs = Addrs}, Key) ->
    % TODO: A proper consistent hashing.
    {Key, hd(Addrs)}.

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The result Addr's list might
% have length <= N.  This version is useful for multiget.
choose_addrs(Bucket, Keys, N) when is_list(Keys) ->
    lists:map(fun (Key) -> choose_addrs(Bucket, Key, N) end, Keys);

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The result Addr's list might
% have length <= N.
choose_addrs(#mc_bucket{addrs = Addrs}, Key, N) ->
    % TODO: A proper consistent hashing.
    {Key, lists:sublist(Addrs, N)}.

foreach_addr(#mc_bucket{addrs = Addrs}, VisitorFun) ->
    lists:foreach(VisitorFun, Addrs).

% ------------------------------------------------

bucket_test() ->
    (fun () ->
        B1 = create(pool1, [a1], buck1),
        ?assertMatch({key1, a1}, choose_addr(B1, key1)),
        ?assertMatch({key2, a1}, choose_addr(B1, key2)),
        ?assertMatch([{key3, a1}, {key4, a1}],
                     choose_addr(B1, [key3, key4])),
        ?assertMatch({key5, [a1]}, choose_addrs(B1, key5, 1)),
        ?assertMatch({key6, [a1]}, choose_addrs(B1, key6, 1)),
        ?assertMatch([{key7, [a1]}, {key8, [a1]}],
                     choose_addrs(B1, [key7, key8], 1)),
        ok
     end)().

