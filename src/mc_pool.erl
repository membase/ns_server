-module(mc_pool).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% API for pool.

%% TODO: A proper implementation.
%% TODO: Consider replacing implementation with gen_server.

create() ->
    create(["127.0.0.1:11211"]).

create(Addrs) ->
    create(Addrs, ["default"]).

create(Addrs, Buckets) ->
    #mc_pool{addrs = Addrs, buckets = Buckets}.

get_bucket(#mc_pool{buckets = Buckets}, BucketId) ->
    % TODO: Need a more efficient list find impl.
    {ok, hd([B || B <- Buckets, B#mc_bucket.id =:= BucketId])}.

foreach_bucket(#mc_pool{buckets = Buckets}, VisitorFun) ->
    lists:foreach(VisitorFun, Buckets).

