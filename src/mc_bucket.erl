-module(mc_bucket).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% API for buckets.

%% TODO: A proper implementation.
%% TODO: Consider replacing implementation with gen_server.

create(Pool, BucketAddrs, BucketKey) ->
    #mc_bucket{pool = Pool, addrs = BucketAddrs, key = BucketKey}.

% Choose the Addr that should contain the Key.
choose_addr(#mc_bucket{addrs = Addrs}, _Key) ->
    % TODO: A proper consistent hashing.
    {ok, hd(Addrs)}.

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The result Addr's list might
% have length <= N.
choose_addrs(#mc_bucket{addrs = Addrs}, _Key, N) ->
    % TODO: A proper consistent hashing.
    {ok, lists:sublist(Addrs, N)}.

foreach_addr(#mc_bucket{addrs = Addrs}, VisitorFun) ->
    lists:foreach(VisitorFun, Addrs).
