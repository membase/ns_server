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
    create(Addrs, [mc_bucket:create("default", Addrs)]).

create(Addrs, Buckets) ->
    #mc_pool{addrs = Addrs, buckets = Buckets}.

% Returns {value, Bucket} or false.
get_bucket(#mc_pool{buckets = Buckets}, BucketId) ->
    lists:keysearch(BucketId, #mc_bucket.id, Buckets).

foreach_bucket(#mc_pool{buckets = Buckets}, VisitorFun) ->
    lists:foreach(VisitorFun, Buckets).

% ------------------------------------------------

get_bucket_test() ->
    B1 = mc_bucket:create("default", ["127.0.0.1:11211"]),
    P1 = create(),
    ?assertMatch({value, B1}, get_bucket(P1, "default")),
    ok.

foreach_bucket_test() ->
    B1 = mc_bucket:create("default", ["127.0.0.1:11211"]),
    P1 = create(),
    foreach_bucket(P1, fun (B) ->
                           ?assertMatch(B1, B)
                       end),
    ok.

