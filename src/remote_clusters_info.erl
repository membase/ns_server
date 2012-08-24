%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% This service provides a way to get an information about remote
%% clusters. The main consumer for it is xdc_rep_manager.
%%
%% There're several important functions exposed:
%%
%%  - fetch_remote_cluster/{1,2}
%%
%%    Basically returns a list of nodes that remote cluster have. Used by
%%    menelaus_web_remote_clusters. This function always goes to remote
%%    cluster no matter if there's a cached information or not.
%%
%%  - get_remote_bucket/{3,4}
%%
%%    Returns remote bucket information by remote cluster name and bucket
%%    name. The most important piece here is a vbucket map for that
%%    bucket. Vbucket map is returned as an erlang dict mapping vbuckets to
%%    replication chains. The chain contains ready URLs to remote vbucket
%%    databases so that xdc_rep_manager could just easily use it without any
%%    additional preparation. There's one exception though. Replication chains
%%    can contain 'undefined' atoms where there's corresponding master or
%%    replica for the vbucket.
%%
%%    `Through` parameter controls if client can accept stale
%%    information. When set to 'true' the most up to date information will be
%%    queried from the remote cluster. When set to 'false' cached information
%%    (if it's existent) will be returned.
%%
%%  - get_remote_bucket_by_ref/{2,3}
%%
%%    Same as previous functions. But remote cluster and bucket is identified
%%    by the 'target' reference stored in replication document.
%%
%%  - remote_bucket_reference/2
%%
%%    Construct remote bucket reference that can be used by
%%    get_remote_bucket_by_ref functions.

%% The service maintains protected ets table that is used to cache obtained
%% information. It's structure is as follows.
%%
%%   clusters: an ordered list of UUIDs of cached remote clusters
%%
%%   <UUID>: a cached information for the remote cluster denoted by <UUID>
%%
%%   {buckets, <UUID>}: an ordered list of buckets cached for a cluster
%%                      denoted by <UUID>
%%
%%   {bucket, <UUID>, <RemoteBucketName>}: a cached information about remote
%%                                         bucket <RemoteBucketName> on the
%%                                         cluster denoted by <UUID>

-module(remote_clusters_info).

-behaviour(gen_server).

%% API
-export([start_link/0]).

-export([fetch_remote_cluster/1, fetch_remote_cluster/2,
         get_remote_bucket/3, get_remote_bucket/4,
         get_remote_bucket_by_ref/2, get_remote_bucket_by_ref/3,
         remote_bucket_reference/2,
         invalidate_remote_bucket/2, invalidate_remote_bucket_by_ref/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-import(menelaus_web_remote_clusters,
        [get_remote_clusters/0, cas_remote_clusters/2]).

-include("ns_common.hrl").
-include("couch_db.hrl").
-include("remote_clusters_info.hrl").
-include_lib("eunit/include/eunit.hrl").


-define(CACHE, ?MODULE).

-define(GC_INTERVAL,
        ns_config_ets_dup:unreliable_read_key(
          {node, node(), remote_clusters_info_gc_interval}, 60000)).
-define(FETCH_CLUSTER_TIMEOUT,
        ns_config_ets_dup:get_timeout(remote_info_fetch_cluster, 15000)).
-define(GET_BUCKET_TIMEOUT,
        ns_config_ets_dup:get_timeout(remote_info_get_bucket, 30000)).

-define(CAS_TRIES,
        ns_config_ets_dup:unreliable_read_key(
          {node, node(), remote_clusters_info_cas_tries}, 10)).
-define(CONFIG_UPDATE_INTERVAL,
        ns_config_ets_dup:unreliable_read_key(
          {node, node(), remote_clusters_info_config_update_interval}, 10000)).

-record(state, {cache_path :: string(),
                scheduled_config_updates :: set()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec fetch_remote_cluster(list()) -> {ok, #remote_cluster{}} |
                                      {error, timeout} |
                                      {error, rest_error, Msg, Details} |
                                      {error, client_error, Msg} |
                                      {error, bad_value, Msg} |
                                      {error, {bad_value, Field}, Msg} |
                                      {error, {missing_field, Field}, Msg}
  when Details :: {error, term()} | {bad_status, integer(), string()},
       Msg :: binary(),
       Field :: binary().
fetch_remote_cluster(Cluster) ->
    fetch_remote_cluster(Cluster, ?FETCH_CLUSTER_TIMEOUT).

-spec fetch_remote_cluster(list(), integer()) ->
                                  {ok, #remote_cluster{}} |
                                  {error, timeout} |
                                  {error, rest_error, Msg, Details} |
                                  {error, client_error, Msg} |
                                  {error, bad_value, Msg} |
                                  {error, {bad_value, Field}, Msg} |
                                  {error, {missing_field, Field}, Msg}
  when Details :: {error, term()} | {bad_status, integer(), string()},
       Msg :: binary(),
       Field :: binary().
fetch_remote_cluster(Cluster, Timeout) ->
    gen_server:call(?MODULE, {fetch_remote_cluster, Cluster, Timeout}, infinity).

-spec get_remote_bucket_by_ref(binary(), boolean()) ->
                                      {ok, #remote_bucket{}} |
                                      {error, cluster_not_found, Msg} |
                                      {error, timeout} |
                                      {error, rest_error, Msg, Details} |
                                      {error, client_error, Msg} |
                                      {error, bad_value, Msg} |
                                      {error, {bad_value, Field}, Msg} |
                                      {error, {missing_field, Field}, Msg} |
                                      {error, all_nodes_failed, Msg} |
                                      {error, other_cluster, Msg} |
                                      {error, not_capable, Msg} |
                                      {error, not_present, Msg}
  when Details :: {error, term()} | {bad_status, integer(), string()},
       Msg :: binary(),
       Field :: binary().
get_remote_bucket_by_ref(Reference, Through) ->
    get_remote_bucket_by_ref(Reference, Through, ?GET_BUCKET_TIMEOUT).

-spec get_remote_bucket_by_ref(binary(), boolean(), integer()) ->
                                      {ok, #remote_bucket{}} |
                                      {error, cluster_not_found, Msg} |
                                      {error, timeout} |
                                      {error, rest_error, Msg, Details} |
                                      {error, client_error, Msg} |
                                      {error, bad_value, Msg} |
                                      {error, {bad_value, Field}, Msg} |
                                      {error, {missing_field, Field}, Msg} |
                                      {error, all_nodes_failed, Msg} |
                                      {error, other_cluster, Msg} |
                                      {error, not_capable, Msg} |
                                      {error, not_present, Msg}
  when Details :: {error, term()} | {bad_status, integer(), string()},
       Msg :: binary(),
       Field :: binary().
get_remote_bucket_by_ref(Reference, Through, Timeout) ->
    {ok, {ClusterUUID, BucketName}} = parse_remote_bucket_reference(Reference),
    Cluster = find_cluster_by_uuid(ClusterUUID),
    gen_server:call(?MODULE,
                    {get_remote_bucket, Cluster,
                                        BucketName, Through, Timeout}, infinity).

invalidate_remote_bucket_by_ref(Reference) ->
    {ok, {ClusterUUID, BucketName}} = parse_remote_bucket_reference(Reference),
    invalidate_remote_bucket(ClusterUUID, BucketName).

-spec get_remote_bucket(string(), bucket_name(), boolean()) ->
                               {ok, #remote_bucket{}} |
                               {error, cluster_not_found, Msg} |
                               {error, timeout} |
                               {error, rest_error, Msg, Details} |
                               {error, client_error, Msg} |
                               {error, bad_value, Msg} |
                               {error, {bad_value, Field}, Msg} |
                               {error, {missing_field, Field}, Msg} |
                               {error, all_nodes_failed, Msg} |
                               {error, other_cluster, Msg} |
                               {error, not_capable, Msg} |
                               {error, not_present, Msg}
  when Details :: {error, term()} | {bad_status, integer(), string()},
       Msg :: binary(),
       Field :: binary().
get_remote_bucket(ClusterName, Bucket, Through) ->
    get_remote_bucket(ClusterName, Bucket, Through, ?GET_BUCKET_TIMEOUT).

-spec get_remote_bucket(string(), bucket_name(), boolean(), integer()) ->
                               {ok, #remote_bucket{}} |
                               {error, cluster_not_found, Msg} |
                               {error, timeout} |
                               {error, rest_error, Msg, Details} |
                               {error, client_error, Msg} |
                               {error, bad_value, Msg} |
                               {error, {bad_value, Field}, Msg} |
                               {error, {missing_field, Field}, Msg} |
                               {error, all_nodes_failed, Msg} |
                               {error, other_cluster, Msg} |
                               {error, not_capable, Msg} |
                               {error, not_present, Msg}
  when Details :: {error, term()} | {bad_status, integer(), string()},
       Msg :: binary(),
       Field :: binary().
get_remote_bucket(ClusterName, Bucket, Through, Timeout) ->
    Cluster = find_cluster_by_name(ClusterName),
    gen_server:call(?MODULE,
                    {get_remote_bucket, Cluster, Bucket, Through, Timeout}, infinity).


invalidate_remote_bucket(ClusterName, Bucket) ->
    Cluster = find_cluster_by_name(ClusterName),
    case Cluster of
        {error, _, _} ->
            Cluster;
        _ ->
            gen_server:call(?MODULE,
                            {invalidate_remote_bucket, Cluster, Bucket}, infinity)
    end.

%% gen_server callbacks
init([]) ->
    CachePath = path_config:component_path(data, "remote_clusters_cache"),
    ok = read_or_create_table(?CACHE, CachePath),
    ets:insert_new(?CACHE, {clusters, []}),

    schedule_gc(),

    {ok, #state{cache_path=CachePath,
                scheduled_config_updates=sets:new()}}.

handle_call({fetch_remote_cluster, Cluster, Timeout}, From, State) ->
    reply_async(
      From, Timeout,
      fun () ->
              R = remote_cluster(Cluster),
              case R of
                  {ok, #remote_cluster{uuid=UUID} = RemoteCluster} ->
                      ?MODULE ! {cache_remote_cluster, UUID, RemoteCluster};
                  _ ->
                      ok
              end,

              R
      end),

    {noreply, State};
handle_call({invalidate_remote_bucket, Cluster, Bucket}, _From, State) ->
    UUID = proplists:get_value(uuid, Cluster),
    true = (UUID =/= undefined),
    ets:delete(?CACHE, {bucket, UUID, Bucket}),
    {reply, ok, State};
handle_call({get_remote_bucket, Cluster, Bucket, false, Timeout}, From, State) ->
    UUID = proplists:get_value(uuid, Cluster),
    true = (UUID =/= undefined),

    case ets:lookup(?CACHE, {bucket, UUID, Bucket}) of
        [] ->
            handle_call({get_remote_bucket, Cluster, Bucket, true, Timeout},
                        From, State);
        [{_, Cached}] ->
            {reply, {ok, Cached}, State}
    end;
handle_call({get_remote_bucket, Cluster, Bucket, true, Timeout}, From, State) ->
    Username = proplists:get_value(username, Cluster),
    Password = proplists:get_value(password, Cluster),
    UUID = proplists:get_value(uuid, Cluster),

    true = (Username =/= undefined),
    true = (Password =/= undefined),
    true = (UUID =/= undefined),

    RemoteCluster =
        case ets:lookup(?CACHE, UUID) of
            [] ->
                Hostname = proplists:get_value(hostname, Cluster),
                true = (Hostname =/= undefined),

                Nodes = [hostname_to_remote_node(Hostname)],
                #remote_cluster{uuid=UUID, nodes=Nodes};
            [{UUID, FoundCluster}] ->
                FoundCluster
        end,

    reply_async(
      From, Timeout,
      fun () ->
              R = remote_cluster_and_bucket(RemoteCluster, Bucket, Username, Password),
              case R of
                  {ok, {NewRemoteCluster, RemoteBucket}} ->
                      ?MODULE ! {cache_remote_cluster, UUID, NewRemoteCluster},
                      ?MODULE ! {cache_remote_bucket, {UUID, Bucket}, RemoteBucket},

                      {ok, RemoteBucket};
                  Error ->
                      Error
              end
      end),

    {noreply, State};
handle_call(Request, From, State) ->
    ?log_warning("Got unexpected call request: ~p", [{Request, From}]),
    {reply, unhandled, State}.

handle_cast(Msg, State) ->
    ?log_warning("Got unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({cache_remote_cluster, UUID, RemoteCluster0}, State) ->
    RemoteCluster = last_cache_request(cache_remote_cluster, UUID, RemoteCluster0),

    true = ets:insert(?CACHE, {UUID, RemoteCluster}),

    [{clusters, Clusters}] = ets:lookup(?CACHE, clusters),
    NewClusters = ordsets:add_element(UUID, Clusters),
    true = ets:insert(?CACHE, {clusters, NewClusters}),

    ets:insert_new(?CACHE, {{buckets, UUID}, []}),
    {noreply, maybe_schedule_cluster_config_update(RemoteCluster, State)};
handle_info({cache_remote_bucket, {UUID, Bucket} = Id, RemoteBucket0}, State) ->
    [{_, Buckets}] = ets:lookup(?CACHE, {buckets, UUID}),
    NewBuckets = ordsets:add_element(Bucket, Buckets),
    true = ets:insert(?CACHE, {{buckets, UUID}, NewBuckets}),

    RemoteBucket = last_cache_request(cache_remote_bucket, Id, RemoteBucket0),
    true = ets:insert(?CACHE, {{bucket, UUID, Bucket}, RemoteBucket}),

    {noreply, State};
handle_info(gc, #state{cache_path=CachePath} = State) ->
    gc(),
    dump_table(?CACHE, CachePath),
    schedule_gc(),
    {noreply, State};
handle_info({update_cluster_config, UUID, Tries}, State) ->
    LastAttempt = (Tries =:= 1),

    NewState =
        case try_update_cluster_config(UUID, LastAttempt) orelse LastAttempt of
            true ->
                Scheduled = State#state.scheduled_config_updates,
                NewScheduled = sets:del_element(UUID, Scheduled),
                State#state{scheduled_config_updates=NewScheduled};
            false ->
                schedule_cluster_config_update(UUID, Tries - 1),
                State
        end,

    {noreply, NewState};
handle_info(Info, State) ->
    ?log_warning("Got unexpected info: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% Internal functions
read_or_create_table(TableName, Path) ->
    Read =
        case filelib:is_regular(Path) of
            true ->
                ?log_info("Reading ~p content from ~s", [TableName, Path]),
                case ets:file2tab(Path, [{verify, true}]) of
                    {ok, TableName} ->
                        true;
                    {error, Error} ->
                        ?log_warning("Failed to read ~p content from ~s: ~p",
                                     [TableName, Path, Error]),
                        false
                end;
        false ->
                false
        end,

    case Read of
        true ->
            ok;
        false ->
            TableName = ets:new(TableName, [named_table, set, protected]),
            ok
    end.

dump_table(TableName, Path) ->
    case ets:tab2file(TableName, Path) of
        ok ->
            ok;
        {error, Error} ->
            ?log_error("Failed to dump table `~s` to file `~s`: ~p",
                       [TableName, Path, Error]),
            ok
    end.

expect(Value, Context, Extract, K) ->
    case Extract(Value, Context) of
        {ok, ExtractedValue} ->
            K(ExtractedValue);
        {bad_value, Msg} ->
            ?log_warning("~s:~n~p", [Msg, Value]),
            {error, bad_value, Msg}
    end.

extract_object(Value, Context) ->
    case Value of
        {struct, ActualValue} ->
            {ok, ActualValue};
        _ ->
            Msg = io_lib:format("(~s) invalid object", [Context]),
            {bad_value, iolist_to_binary(Msg)}
    end.

expect_object(Value, Context, K) ->
    expect(Value, Context, fun extract_object/2, K).

expect_nested(Field, Props, Context, Extract, K) ->
    case proplists:get_value(Field, Props) of
        undefined ->
            Msg = io_lib:format("(~s) missing field `~s`", [Context, Field]),
            ?log_warning("~s:~n~p", [Msg, Props]),
            {error, {missing_field, Field}, iolist_to_binary(Msg)};
        Value ->
            ExtContext = io_lib:format("field `~s` in ~s", [Field, Context]),
            case Extract(Value, ExtContext) of
                {ok, ActualValue} ->
                    K(ActualValue);
                {bad_value, Msg} ->
                    ?log_warning("~s:~n~p", [Msg, Value]),
                    {error, {bad_value, Field}, Msg}
            end
    end.

expect_nested_object(Field, Props, Context, K) ->
    expect_nested(Field, Props, Context, fun extract_object/2, K).

extract_string(MaybeBinary, Context) ->
    case is_binary(MaybeBinary) of
        true ->
            {ok, MaybeBinary};
        false ->
            Msg = io_lib:format("(~s) got invalid string", [Context]),
            {bad_value, iolist_to_binary(Msg)}
    end.

expect_string(Value, Context, K) ->
    expect(Value, Context, fun extract_string/2, K).

expect_nested_string(Field, Props, Context, K) ->
    expect_nested(Field, Props, Context, fun extract_string/2, K).

extract_array(MaybeArray, Context) ->
    case is_list(MaybeArray) of
        true ->
            {ok, MaybeArray};
        false ->
            Msg = io_lib:format("(~s) got invalid array", [Context]),
            {bad_value, iolist_to_binary(Msg)}
    end.

expect_array(Value, Context, K) ->
    expect(Value, Context, fun extract_array/2, K).

expect_nested_array(Field, Props, Context, K) ->
    expect_nested(Field, Props, Context, fun extract_array/2, K).

extract_number(MaybeNumber, Context) ->
    case is_integer(MaybeNumber) of
        true ->
            {ok, MaybeNumber};
        false ->
            Msg = io_lib:format("(~s) got invalid number", [Context]),
            {bad_value, iolist_to_binary(Msg)}
    end.

expect_number(Value, Context, K) ->
    expect(Value, Context, fun extract_number/2, K).

expect_nested_number(Field, Props, Context, K) ->
    expect_nested(Field, Props, Context, fun extract_number/2, K).

with_pools(JsonGet, K) ->
    Context = <<"/pools response">>,

    JsonGet(
      "/pools",
      fun (PoolsRaw) ->
              expect_object(
                PoolsRaw, Context,
                fun (Pools) ->
                        expect_nested_string(
                          <<"uuid">>, Pools, Context,
                          fun (UUID) ->
                                  K(Pools, UUID)
                          end)
                end)
      end).

with_default_pool_details(Pools, JsonGet, K) ->
    expect_nested_array(
      <<"pools">>, Pools, <<"/pools response">>,
      fun ([DefaultPool | _]) ->
              expect_object(
                DefaultPool,
                <<"pools list in /pools response">>,
                fun (DefaultPoolObject) ->
                        expect_nested_string(
                          <<"uri">>, DefaultPoolObject,
                          <<"default pool object">>,
                          fun (URI) ->
                                  JsonGet(
                                    binary_to_list(URI),
                                    fun (PoolDetails) ->
                                            expect_object(
                                              PoolDetails,
                                              <<"default pool details">>, K)
                                    end)
                          end)
                end)
      end).

with_buckets(PoolDetails, JsonGet, K) ->
    expect_nested_object(
      <<"buckets">>, PoolDetails, <<"default pool details">>,
      fun (BucketsObject) ->
              expect_nested_string(
                <<"uri">>, BucketsObject,
                <<"buckets object in default pool details">>,
                fun (URI) ->
                        JsonGet(
                          binary_to_list(URI),
                          fun (Buckets) ->
                                  expect_array(
                                    Buckets,
                                    <<"buckets details">>, K)
                          end)
                end)
      end).

with_bucket([], BucketName, _K) ->
    Msg = io_lib:format("Bucket `~s` not found.", [BucketName]),
    {error, not_present, iolist_to_binary(Msg)};
with_bucket([Bucket | Rest], BucketName, K) ->
    expect_object(
      Bucket,
      <<"bucket details">>,
      fun (BucketObject) ->
              expect_nested_string(
                <<"name">>, BucketObject, <<"bucket details">>,
                fun (Name) ->
                        case Name =:= BucketName of
                            true ->
                                with_bucket_tail(Name, BucketObject, K);
                            false ->
                                with_bucket(Rest, BucketName, K)
                        end
                end)
      end).

with_bucket_tail(Name, BucketObject, K) ->
    %% server prior to 2.0 don't have bucketCapabilities at all
    CapsRaw = proplists:get_value(<<"bucketCapabilities">>, BucketObject, []),

    expect_array(
      CapsRaw, <<"bucket capabilities">>,
      fun (Caps) ->
              case lists:member(<<"couchapi">>, Caps) of
                  true ->
                      expect_nested_string(
                        <<"uuid">>, BucketObject, <<"bucket details">>,
                        fun (BucketUUID) ->
                                K(BucketObject, BucketUUID)
                        end);
                  false ->
                      Msg = io_lib:format("Incompatible remote bucket `~s`", [Name]),
                      {error, not_capable, iolist_to_binary(Msg)}
              end
      end).

remote_cluster(Cluster) ->
    Username = proplists:get_value(username, Cluster),
    Password = proplists:get_value(password, Cluster),
    Hostname = proplists:get_value(hostname, Cluster),

    true = (Username =/= undefined),
    true = (Password =/= undefined),
    true = (Hostname =/= undefined),

    {Host, Port} = host_and_port(Hostname),

    JsonGet = mk_json_get(Host, Port, Username, Password),
    do_remote_cluster(JsonGet).

do_remote_cluster(JsonGet) ->
    with_pools(
      JsonGet,
      fun (Pools, UUID) ->
              with_default_pool_details(
                Pools, JsonGet,
                fun (PoolDetails) ->
                        with_nodes(
                          PoolDetails, <<"default pool details">>,
                          [{<<"hostname">>, fun extract_string/2}],
                          fun (NodeProps) ->
                                  Nodes = lists:map(fun props_to_remote_node/1,
                                                    NodeProps),
                                  SortedNodes = lists:sort(Nodes),

                                  {ok, #remote_cluster{uuid=UUID,
                                                       nodes=SortedNodes}}
                          end)
                end)
      end).

with_nodes(Object, Context, Props, K) ->
    expect_nested_array(
      <<"nodes">>, Object, Context,
      fun (NodeList) ->
              Nodes =
                  lists:flatmap(
                    fun (Node) ->
                            extract_node_props(Props, Context, Node)
                    end, NodeList),
              case Nodes of
                  [] ->
                      Msg = io_lib:format("(~s) unable to extract any nodes",
                                          [Context]),
                      {error, {bad_value, <<"nodes">>}, iolist_to_binary(Msg)};
                  _ ->
                      K(Nodes)
              end
      end).

extract_node_props(Props, Context, {struct, Node}) ->
    R =
        lists:foldl(
          fun ({Prop, Extract}, Acc) ->
                  case proplists:get_value(Prop, Node) of
                      undefined ->
                          ?log_warning("Missing `~s` field in node info:~n~p",
                                       [Prop, Node]),
                          Acc;
                      Value ->
                          case Extract(Value, Context) of
                              {ok, FinalValue} ->
                                  [{Prop, FinalValue} | Acc];
                              {bad_value, Msg} ->
                                  ?log_warning("~s:~n~p", [Msg, Value]),
                                  Acc
                          end
                  end
          end, [], Props),
    [R];
extract_node_props(_Props, Context, Node) ->
    ?log_warning("(~s) got invalid node info value:~n~p", [Context, Node]),
    [].

props_to_remote_node(Props) ->
    Hostname = proplists:get_value(<<"hostname">>, Props),
    true = (Hostname =/= undefined),

    hostname_to_remote_node(binary_to_list(Hostname)).

hostname_to_remote_node(Hostname) ->
    {Host, Port} = host_and_port(Hostname),
    #remote_node{host=Host, port=Port}.

remote_node_to_hostname(#remote_node{host=Host, port=Port}) ->
    Host ++ ":" ++ integer_to_list(Port).

host_and_port(Hostname) ->
    case re:run(Hostname, <<"^(.*):([0-9]*)$">>,
                [anchored, {capture, all_but_first, list}]) of
        nomatch ->
            {Hostname, 8091};
        {match, [Host, PortStr]} ->
            try
                {Host, list_to_integer(PortStr)}
            catch
                error:badarg ->
                    {Hostname, 8091}
            end
    end.

remote_cluster_and_bucket(#remote_cluster{nodes=Nodes,
                                          uuid=UUID},
                          BucketStr, Username, Password) ->
    Bucket = list_to_binary(BucketStr),
    ShuffledNodes = misc:shuffle(Nodes),

    remote_bucket_from_nodes(ShuffledNodes, Bucket, Username, Password, UUID).

remote_bucket_from_nodes([], _, _, _, _) ->
    {error, all_nodes_failed,
     <<"Failed to grab remote bucket info from any of known nodes">>};
remote_bucket_from_nodes([Node | Rest], Bucket, Username, Password, UUID) ->
    R = remote_bucket(Node, Bucket, Username, Password, UUID),

    case R of
        {ok, _} ->
            R;
        {error, Type, _} when Type =:= not_present;
                              Type =:= not_capable ->
            R;
        _Other ->
            remote_bucket_from_nodes(Rest, Bucket, Username, Password, UUID)
    end.

remote_bucket(#remote_node{host=Host, port=Port},
              Bucket, Username, Password, UUID) ->
    Creds = {Username, Password},

    JsonGet = mk_json_get(Host, Port, Username, Password),

    with_pools(
      JsonGet,
      fun (Pools, ActualUUID) ->
              case ActualUUID =:= UUID of
                  true ->
                      with_default_pool_details(
                        Pools, JsonGet,
                        fun (PoolDetails) ->
                                remote_bucket_with_pool_details(PoolDetails,
                                                                UUID,
                                                                Bucket,
                                                                Creds, JsonGet)

                        end);
                  false ->
                      ?log_info("Attempted to get vbucket map for bucket `~s` "
                                "from remote node ~s:~b. But cluster's "
                                "uuid (~s) does not match expected one (~s)",
                                [Bucket, Host, Port, ActualUUID, UUID]),
                      {error, other_cluster,
                       <<"Remote cluster uuid doesn't match expected one.">>}
              end
      end).

remote_bucket_with_pool_details(PoolDetails, UUID, Bucket, Creds, JsonGet) ->
    with_nodes(
      PoolDetails, <<"default pool details">>,
      [{<<"hostname">>, fun extract_string/2}],
      fun (PoolNodeProps) ->
              with_buckets(
                PoolDetails, JsonGet,
                fun (Buckets) ->
                        with_bucket(
                          Buckets, Bucket,
                          fun (BucketObject, BucketUUID) ->
                                  with_nodes(
                                    BucketObject, <<"bucket details">>,
                                    [{<<"hostname">>, fun extract_string/2},
                                     {<<"couchApiBase">>, fun extract_string/2},
                                     {<<"ports">>, fun extract_object/2}],
                                    fun (BucketNodeProps) ->
                                            remote_bucket_with_bucket(BucketObject,
                                                                      UUID,
                                                                      BucketUUID,
                                                                      PoolNodeProps,
                                                                      BucketNodeProps,
                                                                      Creds)
                                    end)
                          end)
                end)
      end).

remote_bucket_with_bucket(BucketObject, UUID,
                          BucketUUID, PoolNodeProps, BucketNodeProps, Creds) ->
    PoolNodes = lists:map(fun props_to_remote_node/1, PoolNodeProps),
    BucketNodes = lists:map(fun props_to_remote_node/1, BucketNodeProps),

    RemoteNodes = lists:usort(PoolNodes ++ BucketNodes),
    RemoteCluster = #remote_cluster{uuid=UUID, nodes=RemoteNodes},

    with_mcd_to_couch_uri_dict(
      BucketNodeProps, Creds,
      fun (McdToCouchDict) ->
              expect_nested_object(
                <<"vBucketServerMap">>, BucketObject, <<"bucket details">>,
                fun (VBucketServerMap) ->
                        remote_bucket_with_server_map(VBucketServerMap, BucketUUID,
                                                      RemoteCluster, McdToCouchDict)
                end)
      end).

remote_bucket_with_server_map(ServerMap, BucketUUID, RemoteCluster, McdToCouchDict) ->
    with_server_list(
      ServerMap,
      fun (ServerList) ->
              case build_ix_to_couch_uri_dict(ServerList,
                                              McdToCouchDict) of
                  {ok, IxToCouchDict} ->
                      expect_nested_array(
                        <<"vBucketMap">>, ServerMap, <<"vbucket server map">>,
                        fun (VBucketMap) ->
                                VBucketMapDict =
                                    build_vbmap(VBucketMap,
                                                BucketUUID, IxToCouchDict),

                                #remote_cluster{uuid=ClusterUUID} = RemoteCluster,
                                RemoteBucket =
                                    #remote_bucket{uuid=BucketUUID,
                                                   cluster_uuid=ClusterUUID,
                                                   vbucket_map=VBucketMapDict},

                                {ok, {RemoteCluster, RemoteBucket}}
                        end);
                  Error ->
                      Error
              end
      end).

build_vbmap(RawVBucketMap, BucketUUID, IxToCouchDict) ->
    do_build_vbmap(RawVBucketMap, BucketUUID, IxToCouchDict, 0, dict:new()).

do_build_vbmap([], _, _, _, D) ->
    D;
do_build_vbmap([ChainRaw | Rest], BucketUUID, IxToCouchDict, VBucket, D) ->
    expect_array(
      ChainRaw, <<"vbucket map chain">>,
      fun (Chain) ->
              case build_vbmap_chain(Chain, BucketUUID, IxToCouchDict, VBucket) of
                  {ok, FinalChain} ->
                      do_build_vbmap(Rest, BucketUUID, IxToCouchDict,
                                     VBucket + 1,
                                     dict:store(VBucket, FinalChain, D));
                  Error ->
                      Error
              end
      end).

build_vbmap_chain(Chain, BucketUUID, IxToCouchDict, VBucket) ->
    do_build_vbmap_chain(Chain, BucketUUID, IxToCouchDict, VBucket, []).

do_build_vbmap_chain([], _, _, _, R) ->
    {ok, lists:reverse(R)};
do_build_vbmap_chain([NodeIxRaw | Rest], BucketUUID, IxToCouchDict, VBucket, R) ->
    expect_number(
      NodeIxRaw, <<"Vbucket map chain">>,
      fun (NodeIx) ->
              case NodeIx of
                  -1 ->
                      do_build_vbmap_chain(Rest, BucketUUID, IxToCouchDict,
                                           VBucket, [undefined | R]);
                  _ ->
                      case dict:find(NodeIx, IxToCouchDict) of
                          error ->
                              Msg = io_lib:format("Invalid node reference in "
                                                  "vbucket map chain: ~p", [NodeIx]),
                              ?log_error("~s", [Msg]),
                              {error, bad_value, iolist_to_binary(Msg)};
                          {ok, URL} ->
                              VBucketURL0 = [URL, "%2f", integer_to_list(VBucket),
                                             "%3b", BucketUUID],
                              VBucketURL = iolist_to_binary(VBucketURL0),
                              do_build_vbmap_chain(Rest, BucketUUID, IxToCouchDict,
                                                   VBucket, [VBucketURL | R])
                      end
              end
      end).

build_ix_to_couch_uri_dict(ServerList, McdToCouchDict) ->
    do_build_ix_to_couch_uri_dict(ServerList, McdToCouchDict, 0, dict:new()).

do_build_ix_to_couch_uri_dict([], _McdToCouchDict, _Ix, D) ->
    {ok, D};
do_build_ix_to_couch_uri_dict([S | Rest], McdToCouchDict, Ix, D) ->
    case dict:find(S, McdToCouchDict) of
        error ->
            ?log_error("Was not able to find node corresponding to server ~s",
                       [S]),

            Msg = io_lib:format("(bucket server list) got bad server value: ~s",
                                [S]),
            {error, bad_value, iolist_to_binary(Msg)};
        {ok, Value} ->
            D1 = dict:store(Ix, Value, D),
            do_build_ix_to_couch_uri_dict(Rest, McdToCouchDict, Ix + 1, D1)
    end.

with_mcd_to_couch_uri_dict(NodeProps, Creds, K) ->
    do_with_mcd_to_couch_uri_dict(NodeProps, dict:new(), Creds, K).

do_with_mcd_to_couch_uri_dict([], Dict, _Creds, K) ->
    K(Dict);
do_with_mcd_to_couch_uri_dict([Props | Rest], Dict, Creds, K) ->
    Hostname = proplists:get_value(<<"hostname">>, Props),
    CouchApiBase0 = proplists:get_value(<<"couchApiBase">>, Props),
    Ports = proplists:get_value(<<"ports">>, Props),

    %% this is ensured by `extract_node_props' function
    true = (Hostname =/= undefined),
    true = (CouchApiBase0 =/= undefined),
    true = (Ports =/= undefined),

    {Host, _Port} = host_and_port(Hostname),
    CouchApiBase = add_credentials(CouchApiBase0, Creds),

    expect_nested_number(
      <<"direct">>, Ports, <<"node ports object">>,
      fun (DirectPort) ->
              McdUri = iolist_to_binary([Host, $:, integer_to_list(DirectPort)]),
              NewDict = dict:store(McdUri, CouchApiBase, Dict),

              do_with_mcd_to_couch_uri_dict(Rest, NewDict, Creds, K)
      end).

add_credentials(URLBinary, {Username, Password}) ->
    URL = binary_to_list(URLBinary),
    {Scheme, Netloc, Path, Query, Fragment} = mochiweb_util:urlsplit(URL),
    Netloc1 = mochiweb_util:quote_plus(Username) ++ ":" ++
        mochiweb_util:quote_plus(Password) ++ "@" ++ Netloc,
    URL1 = mochiweb_util:urlunsplit({Scheme, Netloc1, Path, Query, Fragment}),
    list_to_binary(URL1).

with_server_list(VBucketServerMap, K) ->
    expect_nested_array(
      <<"serverList">>, VBucketServerMap, <<"bucket details">>,
      fun (Servers) ->
              case validate_server_list(Servers) of
                  ok ->
                      K(Servers);
                  Error ->
                      Error
              end
      end).

validate_server_list([]) ->
    ok;
validate_server_list([Server | Rest]) ->
    expect_string(
      Server, <<"bucket server list">>,
      fun (_Value) ->
              validate_server_list(Rest)
      end).

mk_json_get(Host, Port, Username, Password) ->
    fun (Path, K) ->
            R = menelaus_rest:json_request_hilevel(get,
                                                   {Host, Port, Path},
                                                   {Username, Password},
                                                   [{connect_timeout, 5000},
                                                    {timeout, 5000}]),

            case R of
                {ok, Value} ->
                    K(Value);
                {client_error, Body} ->
                    ?log_error("Request to http://~s:****@~s:~b~s returned "
                               "400 status code:~n~p",
                               [mochiweb_util:quote_plus(Username),
                                Host, Port, Path, Body]),

                    %% convert it to the same form as all other errors
                    {error, client_error,
                     <<"Remote cluster returned 400 status code unexpectedly">>};
                Error ->
                    ?log_error("Request to http://~s:****@~s:~b~s failed:~n~p",
                               [mochiweb_util:quote_plus(Username),
                                Host, Port, Path, Error]),
                    Error
            end
    end.

-spec remote_bucket_reference(binary(), bucket_name()) -> binary().
remote_bucket_reference(ClusterUUID, BucketName) ->
    iolist_to_binary(
      [<<"/remoteClusters/">>,
       mochiweb_util:quote_plus(ClusterUUID),
       <<"/buckets/">>,
       mochiweb_util:quote_plus(BucketName)]).

parse_remote_bucket_reference(Reference) ->
    case binary:split(Reference, <<"/">>, [global]) of
        [<<>>, <<"remoteClusters">>, ClusterUUID, <<"buckets">>, BucketName] ->
            ClusterUUID1 = list_to_binary(mochiweb_util:unquote(ClusterUUID)),
            {ok, {ClusterUUID1, mochiweb_util:unquote(BucketName)}};
        _ ->
            {error, bad_reference}
    end.

find_cluster_by_name(ClusterName) ->
    P = fun (Cluster) ->
                Name = proplists:get_value(name, Cluster),
                true = (Name =/= undefined),

                Deleted = proplists:get_value(deleted, Cluster, false),

                Name =:= ClusterName andalso Deleted =:= false
        end,

    case partition_clusters(P, get_remote_clusters()) of
        not_found ->
            {error, cluster_not_found, <<"Requested cluster not found">>};
        {Cluster, _} ->
            Cluster
    end.

partition_clusters(P, Clusters) ->
    do_partition_clusters(P, Clusters, []).

do_partition_clusters(_, [], _) ->
    not_found;
do_partition_clusters(P, [C | Rest], Before) ->
    case P(C) of
        true ->
            {C, Before ++ Rest};
        false ->
            do_partition_clusters(P, Rest, [C | Before])
    end.

last_cache_request(Type, Id, Value) ->
    receive
        {Type, Id, OtherValue} ->
            last_cache_request(Type, Id, OtherValue)
    after
        0 ->
            Value
    end.

get_remote_clusters_ids() ->
    Clusters = get_remote_clusters(),
    lists:sort(
      lists:map(
        fun (Cluster) ->
                UUID = proplists:get_value(uuid, Cluster),
                true = (UUID =/= undefined),

                UUID
        end, Clusters)).

schedule_gc() ->
    erlang:send_after(?GC_INTERVAL, self(), gc).

get_cached_remote_clusters_ids() ->
    [{clusters, Clusters}] = ets:lookup(?CACHE, clusters),
    Clusters.

get_cached_remote_buckets(ClusterId) ->
    [{_, Buckets}] = ets:lookup(?CACHE, {buckets, ClusterId}),
    Buckets.

gc() ->
    Clusters = get_remote_clusters_ids(),
    CachedClusters = get_cached_remote_clusters_ids(),

    RemovedClusters = ordsets:subtract(CachedClusters, Clusters),
    LeftClusters = ordsets:subtract(CachedClusters, RemovedClusters),

    lists:foreach(fun gc_cluster/1, RemovedClusters),
    true = ets:insert(?CACHE, {clusters, LeftClusters}),

    gc_buckets(LeftClusters).

gc_cluster(Cluster) ->
    CachedBuckets = get_cached_remote_buckets(Cluster),
    lists:foreach(
      fun (Bucket) ->
              true = ets:delete(?CACHE, {bucket, Cluster, Bucket})
      end, CachedBuckets),

    true = ets:delete(?CACHE, {buckets, Cluster}),
    true = ets:delete(?CACHE, Cluster).

gc_buckets(CachedClusters) ->
    PresentReplications = build_present_replications_dict(),

    lists:foreach(
      fun (Cluster) ->
              Buckets = case dict:find(Cluster, PresentReplications) of
                            {ok, V} ->
                                V;
                            error ->
                                []
                        end,

              CachedBuckets = get_cached_remote_buckets(Cluster),

              Removed = ordsets:subtract(CachedBuckets, Buckets),
              Left = ordsets:subtract(CachedBuckets, Removed),

              lists:foreach(
                fun (Bucket) ->
                        true = ets:delete(?CACHE, {bucket, Cluster, Bucket})
                end, Removed),

              true = ets:insert(?CACHE, {{buckets, Cluster}, Left})
      end, CachedClusters).

build_present_replications_dict() ->
    Docs = xdc_rdoc_replication_srv:find_all_replication_docs(),
    do_build_present_replications_dict(Docs).

do_build_present_replications_dict(DocPLists) ->
    Pairs = [begin
                 {ok, Pair} = parse_remote_bucket_reference(Target),
                 Pair
             end
             || PList <- DocPLists,
                {<<"target">>, Target} <- PList],
    lists:foldl(
      fun ({UUID, BucketName}, D) ->
              dict:update(UUID,
                          fun (S) ->
                                  ordsets:add_element(BucketName, S)
                          end, [BucketName], D)
      end, dict:new(), Pairs).

-ifdef(EUNIT).

do_build_present_replications_dict_test() ->
    Docs = [[{<<"assd">>, 1},
             {<<"target">>, <<"/remoteClusters/uuu/buckets/asd">>}],
            [],
            [{<<"target">>, <<"/remoteClusters/uuu/buckets/asd">>}],
            [{<<"target">>, <<"/remoteClusters/uuu2/buckets/asd">>}],
            [{<<"target">>, <<"/remoteClusters/uuu/buckets/default">>}]],
    D = do_build_present_replications_dict(Docs),
    DL = lists:sort(dict:to_list(D)),
    ?assertEqual([{<<"uuu">>, ["asd", "default"]},
                  {<<"uuu2">>, ["asd"]}],
                 DL).

-endif.

reply_async(From, Timeout, Computation) ->
    proc_lib:spawn_link(
      fun () ->
              Self = self(),
              Ref = erlang:make_ref(),

              Pid = proc_lib:spawn_link(
                      fun () ->
                              Self ! {Ref, Computation()}
                      end),

              receive
                  {Ref, R} ->
                      gen_server:reply(From, R)
              after
                  Timeout ->
                      erlang:unlink(Pid),
                      erlang:exit(Pid, kill),
                      gen_server:reply(From, {error, timeout})
              end
      end).

maybe_schedule_cluster_config_update(
  #remote_cluster{uuid=UUID} = RemoteCluster,
  #state{scheduled_config_updates=Scheduled} = State) ->
    case not(sets:is_element(UUID, Scheduled)) andalso
        is_cluster_config_update_required(RemoteCluster,
                                          get_remote_clusters()) of
        true ->
            ?log_debug("Scheduling config update for cluster ~s",
                       [UUID]),
            schedule_cluster_config_update(UUID, ?CAS_TRIES),

            NewScheduled = sets:add_element(UUID, Scheduled),
            State#state{scheduled_config_updates=NewScheduled};
        false ->
            State
    end.

schedule_cluster_config_update(UUID, Tries) ->
    random:seed(),
    Sleep = random:uniform(?CONFIG_UPDATE_INTERVAL),
    erlang:send_after(Sleep, self(), {update_cluster_config, UUID, Tries}).

find_cluster_by_uuid(RemoteUUID) ->
    find_cluster_by_uuid(RemoteUUID, get_remote_clusters()).

find_cluster_by_uuid(RemoteUUID, Clusters) ->
    case partition_clusters_by_uuid(RemoteUUID, Clusters) of
        {Cluster, _Rest} ->
            Cluster;
        Error ->
            Error
    end.

partition_clusters_by_uuid(RemoteUUID, Clusters) ->
    P = fun (Cluster) ->
                UUID = proplists:get_value(uuid, Cluster),
                true = (UUID =/= undefined),

                UUID =:= RemoteUUID
        end,

    partition_clusters(P, Clusters).

is_cluster_config_update_required(#remote_cluster{uuid=RemoteUUID,
                                                  nodes=Nodes},
                                  Clusters) ->
    case find_cluster_by_uuid(RemoteUUID, Clusters) of
        not_found ->
            false;
        Cluster ->
            Hostname = proplists:get_value(hostname, Cluster),
            true = (Hostname =/= undefined),
            Node = hostname_to_remote_node(Hostname),

            not(lists:member(Node, Nodes))
    end.

try_update_cluster_config(UUID, LastAttempt) ->
    case ets:lookup(?CACHE, UUID) of
        [] ->
            true;
        [{_, RemoteCluster}] ->
            Clusters = get_remote_clusters(),
            case is_cluster_config_update_required(RemoteCluster, Clusters) of
                true ->
                    {Cluster, Rest} = partition_clusters_by_uuid(UUID, Clusters),

                    ClusterName = proplists:get_value(name, Cluster),
                    Hostname = proplists:get_value(hostname, Cluster),
                    true = (ClusterName =/= undefined),
                    true = (Hostname =/= undefined),

                    #remote_cluster{nodes=RemoteNodes} = RemoteCluster,
                    NewNode = hd(RemoteNodes),
                    NewNodeHostname = remote_node_to_hostname(NewNode),

                    NewCluster =
                        misc:update_proplist(Cluster, [{hostname, NewNodeHostname}]),

                    case cas_remote_clusters(Clusters, [NewCluster | Rest]) of
                        ok ->
                            ale:info(?USER_LOGGER,
                                     "Updated remote cluster `~s` hostname "
                                     "to ~s because old one (~s) is not part of "
                                     "the cluster anymore",
                                     [ClusterName, NewNodeHostname, Hostname]),
                            true;
                        _ ->
                            case LastAttempt of
                                true ->
                                    ?log_error("Exceeded number of retries when "
                                               "trying to update cluster ~s (~s)",
                                               [ClusterName, UUID]);
                                false ->
                                    ok
                            end,
                            false
                    end;
                false ->
                    true
            end
    end.
