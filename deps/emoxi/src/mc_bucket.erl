% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_bucket).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(mc_bucket, {id,     % Bucket id.
                    addrs,  % [mc_addr:create()*].
                    cring,  % From cring:create().
                    config, % Opaque config passed along.
                    auth    % From mc_bucket:get_bucket_auth().
                    }).

-export([bucket_config_default/0,
         bucket_config_make/2,
         bucket_config_make/3,
         bucket_config_set/3,
         bucket_config_get/2,
         bucket_config_get/3,
         bucket_config_delete/2,
         bucket_flush/2,
         addrs/2, addrs/1,
         cring/2, cring/1,
         list/1,
         get/1]).

%% API for buckets.

%% mirrors has_valid_bucket_name in bucket_engine.c
%% and also doesn't allow too long bucket names
is_valid_bucket_name(Name) ->
    %% suboptimal for really long lists, but nthtail is too strict and
    %% I see no easy & fast way to not count beyond 81 chars.
    Len = length(Name),
    Len > 0 andalso Len =< 80
        andalso lists:all(fun (C) ->
                                  (C >= $A andalso C =< $Z)
                                      orelse (C >= $a andalso C =< $z)
                                      orelse (C >= $0 andalso C =< $9)
                                      orelse C =:= $- orelse C =:= $_ orelse C =:= $%
                                      orelse C =:= $.
                          end, Name).

% Callers should consider the returned value to be opaque.
% One day, the return value, for example, might be changed
% into a gen_server Pid.
%
% Addrs is a list of mc_addr:create() records.
%
% For 1.0, these Addrs are to kvcache servers, not to the routers.
%
create(Id, Addrs, Config) ->
    create(Id, Addrs, Config, undefined).

create(Id, Addrs, Config, Auth) ->
    create(Id, Addrs, Config, Auth, ketama, ketama:default_config()).

create(Id, Addrs, Config, Auth, HashMod, HashCfg) ->
    CRingAddrs =
        lists:map(fun(Addr) ->
                      Location = mc_addr:location(Addr),
                      [Host, Port | _] = string:tokens(Location, ":"),
                      PortNum = list_to_integer(Port),
                      {{Host, PortNum}, Addr}
                  end,
                  Addrs),
    CRing = cring:create(CRingAddrs, HashMod, HashCfg),
    #mc_bucket{id = Id,
               addrs = Addrs,
               cring = CRing,
               config = Config,
               auth = Auth}.

id(#mc_bucket{id = Id})          -> Id.
auth(#mc_bucket{auth = Auth})    -> Auth.

addrs({mc_pool_bucket, _PoolId, _BucketId} = BucketRef) ->
    mc_pool:bucket_addrs(BucketRef);
addrs(#mc_bucket{addrs = Addrs}) -> Addrs.

addrs(PoolName, BucketName) ->
    {ok, B} = mc_pool:get_bucket(PoolName, BucketName),
    mc_bucket:addrs(B).

cring({mc_pool_bucket, _PoolId, _BucketId} = BucketRef) ->
    mc_pool:bucket_cring(BucketRef);
cring(#mc_bucket{cring = CRing}) -> CRing.

cring(PoolName, BucketName) ->
    {ok, B} = mc_pool:get_bucket(PoolName, BucketName),
    mc_bucket:cring(B).

% Choose the Addr that should contain the Key.

choose_addr({mc_pool_bucket, _PoolId, _BucketId} = BucketRef, Key) ->
    mc_pool:bucket_choose_addr(BucketRef, Key);

choose_addr(#mc_bucket{cring = CRing}, Key) ->
    case cring:search(CRing, Key) of
        false     -> false;
        {_, Addr} -> {Key, Addr}
    end.

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The number of Addr's returned
% is based on Bucket default replication level.

choose_addrs(Bucket, Key) ->
    % For 1.0, no replication.
    choose_addrs(Bucket, Key, 1).

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The result Addr's list might
% have length <= N.

choose_addrs({mc_pool_bucket, _PoolId, _BucketId} = BucketRef, Key, N) ->
    mc_pool:bucket_choose_addrs(BucketRef, Key, N);

choose_addrs(#mc_bucket{cring = CRing, config = Config}, Key, N) ->
    CRingAddrDataList = cring:search(CRing, Key, N),
    Addrs = lists:map(fun({_CRingAddr, Addr}) -> Addr end,
                      CRingAddrDataList),
    {Key, Addrs, Config}.

get_bucket_auth(BucketConfig) ->
    case proplists:get_value(auth_plain, BucketConfig) of
        undefined                            -> undefined;
        {_AuthName, _AuthPswd} = A           -> {<<"PLAIN">>, A};
        {_ForName, _AuthName, _AuthPswd} = A -> {<<"PLAIN">>, A};
        X -> ns_log:log(?MODULE, 0001, "bucket auth_plain config error: ~p",
                        [X]),
             error
    end.

% ------------------------------------------------

bucket_config_default() ->
    [{auth_plain, undefined},
     {size_per_node, 64}
    ].

bucket_config_make(PoolName, BucketName) ->
    bucket_config_make(PoolName, BucketName, bucket_config_default()).

bucket_config_make(PoolName, BucketName, BucketConfig) ->
    Pools = mc_pool:pools_config_get(),
    PoolConfig =
        case mc_pool:pool_config_get(Pools, PoolName) of
            false -> mc_pool:pool_config_default();
            X     -> X
        end,
    Pools2 =
        mc_pool:pool_config_set(Pools, PoolName,
                                bucket_config_set(PoolConfig,
                                                  BucketName,
                                                  BucketConfig)),
    case Pools =:= Pools2 of
        true  -> true; % No change.
        false -> ns_log:log(?MODULE, 0002, "bucket created: ~p in: ~p",
                            [BucketName, PoolName]),
                 mc_pool:pools_config_set(Pools2) % Created.
    end.

bucket_config_set(PoolConfig, BucketName, BucketConfig) ->
    Buckets = case proplists:get_value(buckets, PoolConfig, false) of
                  false -> [];
                  X     -> X
              end,
    lists:keystore(buckets, 1, PoolConfig,
                   {buckets, lists:keystore(BucketName, 1, Buckets,
                                            {BucketName, BucketConfig})}).

bucket_config_get(PoolConfig, BucketName) ->
    case proplists:get_value(buckets, PoolConfig, false) of
        false   -> false;
        Buckets ->
            case proplists:get_value(BucketName, Buckets, false) of
                false        -> false;
                BucketConfig -> BucketConfig
            end
    end.

bucket_config_get(Pools, PoolName, BucketName) ->
    case mc_pool:pool_config_get(Pools, PoolName) of
        false      -> false;
        PoolConfig -> bucket_config_get(PoolConfig, BucketName)
    end.

bucket_config_delete(PoolConfig, BucketName) ->
    Buckets = case proplists:get_value(buckets, PoolConfig, false) of
                  false -> [];
                  X     -> X
              end,
    lists:keystore(buckets, 1, PoolConfig,
                   {buckets, proplists:delete(BucketName, Buckets)}).

bucket_delete(PoolId, Id) ->
    case mc_pool:pools_config_get() of
        false -> false;
        Pools ->
            case mc_pool:pool_config_get(Pools, PoolId) of
                false -> false;
                PConfig ->
                    PConfig2 = mc_bucket:bucket_config_delete(PConfig, Id),
                    case PConfig =/= PConfig2 of
                        true ->
                            ns_log:log(?MODULE, 0003, "bucket deleted: ~p in: ~p",
                                       [Id, PoolId]),
                            Pools2 = mc_pool:pool_config_set(Pools, PoolId,
                                                             PConfig2),
                            mc_pool:pools_config_set(Pools2),
                            true;
                        false -> false
                    end
            end
    end.


get(Pool) ->
    PoolConf = mc_pool:pool_config_get(mc_pool:pools_config_get(), Pool),
    proplists:get_value(buckets, PoolConf).

list(Pool) ->
    Buckets = mc_bucket:get(Pool),
    lists:map(fun({K, _V}) -> K end, Buckets).

bucket_flush(PoolId, BucketId) ->
    bucket_flush(mc_bucket:addrs(PoolId, BucketId)).

bucket_flush(undefined) -> false;
bucket_flush([])        -> false;
bucket_flush(Addrs) ->
    {NumFwd, Monitors} =
        lists:foldl(
          fun (Addr, Acc) ->
                  mc_downstream:accum(
                    mc_downstream:send(Addr, undefined, ?FLUSH,
                                       {#mc_header{}, #mc_entry{}},
                                               undefined, undefined),
                    Acc)
          end,
          {0, []}, Addrs),
    mc_downstream:await_ok(NumFwd),
    mc_downstream:demonitor(Monitors),
    ok.

% ------------------------------------------------

test_set(PoolName, BucketName, Key, Value) ->
    test_cmd(PoolName, BucketName, Key, ?SET, {#mc_header{},
                                               #mc_entry{key = Key,
                                                         data = Value}}).

test_get(PoolName, BucketName, Key) ->
    test_cmd(PoolName, BucketName, Key, ?GET, {#mc_header{},
                                               #mc_entry{key = Key}}).

test_cmd(PoolName, BucketName, Key, Cmd, CmdArgs) ->
    {ok, B} = mc_pool:get_bucket(PoolName, BucketName),
    {Key, Addr} = mc_bucket:choose_addr(B, Key),
    ResponseFilter = fun(H, E) ->
                             ?debugVal({H, E}),
                             true
                     end,
    {ok, Monitors} = mc_downstream:send(Addr, undefined, Cmd, CmdArgs,
                                        ResponseFilter, undefined),
    1 = mc_downstream:await_ok(1),
    mc_downstream:demonitor(Monitors),
    ok.

% ------------------------------------------------
% Fake hash_key/hash_addr functions for unit testing.

hash_key(_Key, _)   -> 1.
hash_addr(_Addr, _) -> [1].

choose_addr_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, auth, ?MODULE, 1),
    ?assertMatch({key1, A1}, choose_addr(B1, key1)),
    ?assertMatch({key2, A1}, choose_addr(B1, key2)),
    ok.

choose_addrs_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, auth, ?MODULE, 1),
    ?assertMatch({key5, [A1], config}, choose_addrs(B1, key5, 1)),
    ?assertMatch({key6, [A1], config}, choose_addrs(B1, key6, 1)),
    ok.

choose_addr_str_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, auth, ?MODULE, 1),
    ?assertMatch({"key1", A1}, choose_addr(B1, "key1")),
    ?assertMatch({"key2", A1}, choose_addr(B1, "key2")),
    ok.

choose_addrs_str_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, auth, ?MODULE, 1),
    ?assertMatch({"key5", [A1], config}, choose_addrs(B1, "key5", 1)),
    ?assertMatch({"key6", [A1], config}, choose_addrs(B1, "key6", 1)),
    ok.

bucket_config_get_test() ->
    ?assertEqual(false, bucket_config_get([], b)),
    ?assertEqual(false, bucket_config_get([{buckets, []}], b)),
    ?assertEqual(false, bucket_config_get([{buckets, [{x, foo}]}], b)),
    ?assertEqual(foo, bucket_config_get([{buckets, [{b, foo}]}], b)),
    ?assertEqual(foo, bucket_config_get([{buckets, [{b, foo}, {x, bar}]}], b)),
    ?assertEqual(foo, bucket_config_get([{buckets, [{x, bar}, {b, foo}]}], b)),
    ?assertEqual(foo, bucket_config_get([{buckets, [{b, foo}, {x, bar}]}], b)),
    ok.

bucket_config_set_test() ->
    ?assertEqual([{buckets, [{x, xx}]}],
                 bucket_config_set([], x, xx)),
    ?assertEqual([{buckets, [{x, xx}]}],
                 bucket_config_set([{buckets, []}], x, xx)),
    ?assertEqual([{buckets, [{x, xxx}]}],
                 bucket_config_set([{buckets, [{x, xx}]}], x, xxx)),
    ok.

bucket_flush_test() ->
    {ok, _Pid1} = mc_downstream_sup:start_link(),
    {ok, _Pid2} = mc_downstream:start_link(),
    {ok, Sock} = gen_tcp:connect("localhost", 11211,
                                 [binary, {packet, 0}, {active, false}]),
    (fun () ->
        {ok, _H, _E, undefined} =
                 mc_client_binary:cmd(?SET, Sock, undefined, undefined,
                                      {#mc_header{},
                                       #mc_entry{key = <<"a">>,
                                                 data = <<"AAA">>}})
     end)(),
    A1 = mc_addr:create("127.0.0.1:11211", binary),
    B1 = mc_addr:create("localhost:11211", binary),
    ok = bucket_flush([A1, B1]),
    {ok, _H, _E, X} =
        mc_client_binary:cmd(?GET, Sock,
                             fun(#mc_header{status = ?SUCCESS}, ME, CD) ->
                                     dict:store(ME#mc_entry.key,
                                                ME#mc_entry.data,
                                                CD);
                                (_, _, CD) -> CD
                             end,
                             dict:new(),
                             {#mc_header{}, #mc_entry{key = <<"a">>}}),
    ?assertEqual(0, dict:size(X)),
    ok = gen_tcp:close(Sock).

