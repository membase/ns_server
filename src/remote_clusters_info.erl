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
%%
%%  - get_memcached_vbucket_info_by_ref/{3, 4}
%%
%%    -> {ok, {Host :: binary(), MemcachedPort :: integer()}, #remote_bucket{}}
%%       | {error, _} | {error, _, _} % see get_remote_bucket_by_ref for errors
%%
%%    returns information about accessing given vbucket of given
%%    bucket via memcached protocol


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

-type cache_through_mode() :: boolean() | true_using_new_connection.

%% API
-export([start_link/0]).

-export([fetch_remote_cluster/1, fetch_remote_cluster/2,
         get_remote_bucket/3, get_remote_bucket/4,
         get_remote_bucket_by_ref/2, get_remote_bucket_by_ref/3,
         remote_bucket_reference/2, parse_remote_bucket_reference/1,
         invalidate_remote_bucket/2, invalidate_remote_bucket_by_ref/1,
         find_cluster_by_uuid/1,
         get_memcached_vbucket_info_by_ref/3,
         get_memcached_vbucket_info_by_ref/4]).

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
        ns_config:read_key_fast(
          {node, node(), remote_clusters_info_gc_interval}, 60000)).
-define(FETCH_CLUSTER_TIMEOUT,
        ns_config:get_timeout_fast(remote_info_fetch_cluster, 15000)).
-define(GET_BUCKET_TIMEOUT,
        ns_config:get_timeout_fast(remote_info_get_bucket, 30000)).

-define(CAS_TRIES,
        ns_config:read_key_fast(
          {node, node(), remote_clusters_info_cas_tries}, 10)).
-define(CONFIG_UPDATE_INTERVAL,
        ns_config:read_key_fast(
          {node, node(), remote_clusters_info_config_update_interval}, 10000)).

-record(state, {cache_path :: string(),
                scheduled_config_updates :: set(),
                remote_bucket_requests :: dict(),
                remote_bucket_waiters :: dict(),
                remote_bucket_waiters_trefs :: dict()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec fetch_remote_cluster(list()) -> {ok, #remote_cluster{}} |
                                      {error, timeout} |
                                      {error, rest_error, Msg, Details} |
                                      {error, client_error, Msg} |
                                      {error, bad_value, Msg} |
                                      {error, {bad_value, Field}, Msg} |
                                      {error, not_capable, Msg} |
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
                                  {error, not_capable, Msg} |
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

-spec get_remote_bucket(string(), bucket_name(), cache_through_mode()) ->
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

-spec get_remote_bucket(string(), bucket_name(), cache_through_mode(), integer()) ->
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
    case find_cluster_by_name(ClusterName) of
        {error, _, _} = Error ->
            Error;
        Cluster ->
            gen_server:call(?MODULE,
                            {get_remote_bucket, Cluster,
                             Bucket, Through, Timeout}, infinity)
    end.

invalidate_remote_bucket(ClusterName, Bucket) ->
    Cluster = find_cluster_by_name(ClusterName),
    case Cluster of
        {error, _, _} ->
            Cluster;
        _ ->
            gen_server:call(?MODULE,
                            {invalidate_remote_bucket, Cluster, Bucket}, infinity)
    end.

get_memcached_vbucket_info_by_ref(Reference, ForceRefresh, VBucket) ->
    get_memcached_vbucket_info_by_ref(Reference, ForceRefresh, VBucket, ?GET_BUCKET_TIMEOUT).

get_memcached_vbucket_info_by_ref(Reference, ForceRefresh, VBucket, Timeout) ->
    case get_remote_bucket_by_ref(Reference, ForceRefresh, Timeout) of
        {ok, RemoteBucket} ->
            #remote_bucket{raw_vbucket_map = Map,
                           server_list_nodes = ServerListNodes} = RemoteBucket,
            Idx = case dict:find(VBucket, Map) of
                      {ok, Row} -> hd(Row);
                      error -> -1
                  end,
            case Idx < 0 of
                true ->
                    {error, missing_vbucket};
                _ ->
                    {ok, lists:nth(Idx + 1, ServerListNodes), RemoteBucket}
            end;
        Error ->
            Error
    end.

%% gen_server callbacks
init([]) ->
    CachePath = path_config:component_path(data, "remote_clusters_cache_v3"),
    ok = read_or_create_table(?CACHE, CachePath),
    ets:insert_new(?CACHE, {clusters, []}),

    schedule_gc(),

    {ok, #state{cache_path=CachePath,
                scheduled_config_updates=sets:new(),
                remote_bucket_requests=dict:new(),
                remote_bucket_waiters=dict:new(),
                remote_bucket_waiters_trefs=dict:new()}}.

handle_call({fetch_remote_cluster, Cluster, Timeout}, From, State) ->
    Self = self(),
    reply_async(
      From, Timeout,
      fun () ->
              R = remote_cluster(Cluster),
              case R of
                  {ok, #remote_cluster{uuid=UUID} = RemoteCluster} ->
                      Self ! {cache_remote_cluster, UUID, RemoteCluster};
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

    true = is_list(Bucket),

    case ets:lookup(?CACHE, {bucket, UUID, Bucket}) of
        [] ->
            handle_call({get_remote_bucket, Cluster, Bucket, true, Timeout},
                        From, State);
        [{_, Cached}] ->
            case Cached#remote_bucket.cluster_cert =:= proplists:get_value(cert, Cluster) of
                true ->
                    {reply, {ok, Cached}, State};
                false ->
                    ?log_debug("Found cached bucket info (~s/~s), but cert did not match. Forcing refresh",
                               [UUID, Bucket]),
                    handle_call({get_remote_bucket, Cluster, Bucket, true, Timeout},
                                From, State)
            end
    end;
handle_call({get_remote_bucket, Cluster, Bucket, ForceMode, Timeout}, From, State) ->
    Username = proplists:get_value(username, Cluster),
    Password = proplists:get_value(password, Cluster),
    UUID = proplists:get_value(uuid, Cluster),
    Cert = proplists:get_value(cert, Cluster),

    true = (Username =/= undefined),
    true = (Password =/= undefined),
    true = (UUID =/= undefined),

    RemoteCluster0 =
        case {ForceMode, ets:lookup(?CACHE, UUID)} of
            {true_using_new_connection, _} ->
                undefined;
            {_, []} ->
                undefined;
            {_, [{UUID, FoundCluster}]} when FoundCluster#remote_cluster.cert =:= Cert ->
                ?log_debug("FoundCluster: ~p", [FoundCluster]),
                FoundCluster;
            {_, [{UUID, _WrongCertCluster}]} ->
                ?log_debug("Found cluster but cert did not match"),
                undefined
        end,

    RemoteCluster =
        case RemoteCluster0 of
            undefined ->
                Hostname = proplists:get_value(hostname, Cluster),
                true = (Hostname =/= undefined),

                NodeRecord0 = hostname_to_remote_node(Hostname),
                NodeRecord = case Cert of
                                 undefined ->
                                     NodeRecord0;
                                 _ ->
                                     %% TODO: either set all to needed or just one
                                     NodeRecord0#remote_node{ssl_proxy_port = needed_but_unknown,
                                                             https_port = needed_but_unknown}
                             end,
                Nodes = [NodeRecord],
                RV = #remote_cluster{uuid=UUID, nodes=Nodes, cert=Cert},
                ?log_debug("Constructed remote_cluster ~p", [RV]),
                RV;
            _ ->
                RemoteCluster0
        end,

    case ForceMode of
        true ->
            State1 = enqueue_waiter({UUID, Bucket}, From, Timeout, State),
            State2 = request_remote_bucket(RemoteCluster, Bucket,
                                           Username, Password, State1),

            {noreply, State2};
        true_using_new_connection ->
            request_remote_bucket_on_new_conn(RemoteCluster, Bucket,
                                              Username, Password, From),
            {noreply, State}
    end;
handle_call(Request, From, State) ->
    ?log_warning("Got unexpected call request: ~p", [{Request, From}]),
    {reply, unhandled, State}.

handle_cast(Msg, State) ->
    ?log_warning("Got unexpected cast: ~p", [Msg]),
    {noreply, State}.

handle_info({cache_remote_cluster, UUID, RemoteCluster0}, State) ->
    RemoteCluster = last_cache_request(cache_remote_cluster, UUID, RemoteCluster0),
    {noreply, cache_remote_cluster(UUID, RemoteCluster, State)};
handle_info({remote_bucket_request_result, TargetNode, {UUID, Bucket} = Id, R},
            #state{remote_bucket_requests=Requests,
                   remote_bucket_waiters=Waiters,
                   remote_bucket_waiters_trefs=TRefs} = State) ->
    BucketWaiters = misc:dict_get(Id, Waiters, []),
    BucketTRef = misc:dict_get(Id, TRefs, make_ref()),

    BucketRequests0 = dict:fetch(Id, Requests),
    BucketRequests1 = dict:erase(TargetNode, BucketRequests0),
    Requests1 = case dict:size(BucketRequests1) of
                    0 ->
                        dict:erase(Id, Requests);
                    _ ->
                        dict:store(Id, BucketRequests1, Requests)
                end,

    {NewState0, Reply} =
        case R of
            {ok, {RemoteCluster, RemoteBucket}} ->
                State1 = cache_remote_cluster(UUID, RemoteCluster, State),
                State2 = cache_remote_bucket(Id, RemoteBucket, State1),

                {State2, {ok, RemoteBucket}};
            {error, Type, _} when Type =:= not_present;
                                  Type =:= not_capable ->
                {State, R};
            Error ->
                ?log_error("Failed to grab remote bucket `~s`: ~p", [Bucket, Error]),
                case dict:size(BucketRequests1) of
                    0 ->
                        %% no more ongoing request so we just return an error to
                        %% the caller
                        Msg = io_lib:format("Failed to grab remote bucket `~s` "
                                            "from any of known nodes", [Bucket]),

                        {State, {error, all_nodes_failed, iolist_to_binary(Msg)}};
                    _ ->
                        %% let's try to wait for the other requests to return
                        {State, undefined}
                end
        end,

    NewState1 = NewState0#state{remote_bucket_requests=Requests1},
    NewState2 = case Reply of
                    undefined ->
                        NewState1;
                    _ ->
                        cancel_bucket_request_tref(Id, BucketTRef),

                        lists:foreach(
                          fun ({_, Waiter}) ->
                                  gen_server:reply(Waiter, Reply)
                          end, BucketWaiters),

                        Waiters1 = dict:erase(Id, Waiters),
                        TRefs1 = dict:erase(Id, TRefs),
                        %% we don't drop other requests to prevent overloading of
                        %% possibly busy nodes
                        NewState1#state{remote_bucket_waiters=Waiters1,
                                        remote_bucket_waiters_trefs=TRefs1}
                end,

    {noreply, NewState2};
handle_info({remote_bucket_request_timeout, Id},
            #state{remote_bucket_waiters=Waiters,
                   remote_bucket_waiters_trefs=TRefs} = State) ->
    Now = misc:time_to_epoch_ms_int(os:timestamp()),

    BucketWaiters = dict:fetch(Id, Waiters),
    BucketTRef = dict:fetch(Id, TRefs),

    %% tref must already canceled
    false = erlang:read_timer(BucketTRef),

    [{_, From} | BucketWaiters1] = BucketWaiters,
    gen_server:reply(From, {error, timeout}),

    NewState =
        case BucketWaiters1 of
            [] ->
                Waiters1 = dict:erase(Id, Waiters),
                TRefs1 = dict:erase(Id, TRefs),

                State#state{remote_bucket_waiters=Waiters1,
                            remote_bucket_waiters_trefs=TRefs1};
            [{Expiration, _} | _] ->
                Waiters1 = dict:store(Id, BucketWaiters1, Waiters),

                BucketTRef1 = erlang:send_after(max(Expiration - Now, 0), self(),
                                                {remote_bucket_request_timeout, Id}),
                TRefs1 = dict:store(Id, BucketTRef1, TRefs),

                State#state{remote_bucket_waiters=Waiters1,
                            remote_bucket_waiters_trefs=TRefs1}
        end,

    {noreply, NewState};
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

cache_remote_cluster(UUID, RemoteCluster, State) ->
    true = ets:insert(?CACHE, {UUID, RemoteCluster}),

    [{clusters, Clusters}] = ets:lookup(?CACHE, clusters),
    NewClusters = ordsets:add_element(UUID, Clusters),
    true = ets:insert(?CACHE, {clusters, NewClusters}),

    ets:insert_new(?CACHE, {{buckets, UUID}, []}),
    maybe_schedule_cluster_config_update(RemoteCluster, State).

cache_remote_bucket({UUID, Bucket}, RemoteBucket, State) ->
    [{_, Buckets}] = ets:lookup(?CACHE, {buckets, UUID}),
    NewBuckets = ordsets:add_element(Bucket, Buckets),
    true = ets:insert(?CACHE, {{buckets, UUID}, NewBuckets}),
    true = ets:insert(?CACHE, {{bucket, UUID, Bucket}, RemoteBucket}),
    State.

cancel_bucket_request_tref(Id, TRef) ->
    erlang:cancel_timer(TRef),
    receive
        {remote_bucket_request_timeout, Id} ->
            ok
    after 0 ->
            ok
    end.

enqueue_waiter(Id, From, Timeout,
               #state{remote_bucket_waiters=Waiters,
                      remote_bucket_waiters_trefs=TRefs} = State) ->
    Now = misc:time_to_epoch_ms_int(os:timestamp()),
    Expiration = Now + Timeout,

    BucketWaiters = misc:dict_get(Id, Waiters, []),
    BucketTRef = misc:dict_get(Id, TRefs, make_ref()),

    BucketWaiters1 = lists:keymerge(1, BucketWaiters, [{Expiration, From}]),
    First = ({Expiration, From} =:= hd(BucketWaiters1)),

    BucketTRef1 =
        case First of
            true ->
                %% we need to cancel current timer and arm new one
                cancel_bucket_request_tref(Id, BucketTRef),

                erlang:send_after(Timeout, self(),
                                  {remote_bucket_request_timeout, Id});
            false ->
                BucketTRef
    end,

    true = (BucketTRef =/= undefined),

    Waiters1 = dict:store(Id, BucketWaiters1, Waiters),
    TRefs1 = dict:store(Id, BucketTRef1, TRefs),

    State#state{remote_bucket_waiters=Waiters1,
                remote_bucket_waiters_trefs=TRefs1}.

request_remote_bucket_on_new_conn(#remote_cluster{nodes=[Node]} = RemoteCluster,
                                  Bucket, Username, Password, From) ->
    proc_lib:spawn_link(
      fun () ->
              R0 = remote_cluster_and_bucket(Node, RemoteCluster, Bucket,
                                             Username, Password, true),
              R = case R0 of
                      {ok, {_, RemoteBucket}} ->
                          {ok, RemoteBucket};
                      _ ->
                          R0
                  end,
              gen_server:reply(From, R)
      end).


request_remote_bucket(#remote_cluster{nodes=Nodes, uuid=UUID} = RemoteCluster,
                      Bucket, Username, Password,
                      #state{remote_bucket_requests=Requests} = State) ->
    BucketRequests = misc:dict_get({UUID, Bucket}, Requests, dict:new()),

    case request_remote_bucket_random_free_node(Nodes, BucketRequests) of
        failed ->
            %% no free nodes just return old state
            State;
        {ok, FreeNode} ->
            Pid = spawn_request_remote_bucket(FreeNode, RemoteCluster, Bucket,
                                              Username, Password),
            BucketRequests1 = dict:store(FreeNode, Pid, BucketRequests),
            Requests1 = dict:store({UUID, Bucket}, BucketRequests1, Requests),
            State#state{remote_bucket_requests=Requests1}
    end.

request_remote_bucket_random_free_node(Nodes, BucketRequests) ->
    request_remote_bucket_random_free_node(Nodes, undefined, 0, BucketRequests).

request_remote_bucket_random_free_node([], undefined, _, _) ->
    failed;
request_remote_bucket_random_free_node([], R, _, _) ->
    {ok, R};
request_remote_bucket_random_free_node([Node | Rest], R, Count, BucketRequests) ->
    case dict:find(Node, BucketRequests) of
        {ok, _} ->
            request_remote_bucket_random_free_node(Rest, R, Count, BucketRequests);
        error ->
            case random:uniform(Count + 1) of
                1 ->
                    request_remote_bucket_random_free_node(Rest, Node,
                                                           Count + 1, BucketRequests);
                _ ->
                    request_remote_bucket_random_free_node(Rest, R,
                                                           Count + 1, BucketRequests)
            end
    end.

spawn_request_remote_bucket(TargetNode,
                            #remote_cluster{uuid=UUID} = RemoteCluster, Bucket,
                            Username, Password) ->
    Self = self(),
    proc_lib:spawn_link(
      fun () ->
              R = remote_cluster_and_bucket(TargetNode, RemoteCluster, Bucket,
                                            Username, Password, false),
              Self ! {remote_bucket_request_result,
                      TargetNode, {UUID, Bucket}, R}
      end).

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

extract_version(MaybeVersion, Context) ->
    case re:run(MaybeVersion, <<"^([0-9]+)\.([0-9]+)\..+$">>,
                [anchored, {capture, all_but_first, list}]) of
        {match, [V1, V2]} ->
            {ok, [list_to_integer(V1), list_to_integer(V2)]};
        _ ->
            Msg = io_lib:format("(~s) got invalid node version value:~n~p",
                                [Context, MaybeVersion]),
            {bad_value, iolist_to_binary(Msg)}
    end.

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
                end);
          ([]) ->
              {error, not_capable, <<"Remote node is not initialized.">>}
      end).

massage_buckets_list_uri(URI) ->
    SepChar = case binary:match(URI, <<"?">>) of
                  nomatch ->
                      $?;
                  _ ->
                      $&
              end,
    binary_to_list(iolist_to_binary([URI, SepChar, <<"forXDCR=1">>])).

with_buckets(PoolDetails, JsonGet, K) ->
    expect_nested_object(
      <<"buckets">>, PoolDetails, <<"default pool details">>,
      fun (BucketsObject) ->
              expect_nested_string(
                <<"uri">>, BucketsObject,
                <<"buckets object in default pool details">>,
                fun (URI) ->
                        JsonGet(
                          massage_buckets_list_uri(URI),
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

    Cert = proplists:get_value(cert, Cluster),

    MaybeRN = case Cert of
                  undefined ->
                      {ok, hostname_to_remote_node(Hostname)};
                  _ ->
                      fetch_remote_node_record(Host, Port)
              end,

    case MaybeRN of
        {ok, RN} ->
            {JsonGet, _, _, _} = mk_json_get_for_node(RN, Cert,
                                                      Username, Password,
                                                      true),
            do_remote_cluster(JsonGet, Cert);
        {error, rest_error, _Msg, {bad_status, FourX, _Body} = Status} when FourX =:= 404; FourX =:= 403 ->
            Msg = <<"Remote cluster does not support xdcr over ssl. Entire remote cluster needs to be 2.5+ enterprise edition">>,
            {error, rest_error, Msg, Status};
        Error ->
            Error
    end.

fetch_remote_node_record(Host, Port) ->
    JG = mk_plain_json_get(Host, Port, "", "", []),
    RN = #remote_node{host = Host, port = Port},
    JG("/nodes/self/xdcrSSLPorts",
       fun ({struct, [_|_] = PortsKV}) ->
               RN2 = add_port_props(RN, PortsKV),
               #remote_node{ssl_proxy_port = P0,
                            https_port = P1,
                            https_capi_port = P2} = RN2,
               case (P0 =:= undefined
                     orelse P1 =:= undefined
                     orelse P2 =:= undefined) of
                   true ->
                       %% TODO: error message
                       {error, failed_to_get_proxy_port};
                   false ->
                       {ok, RN2}
               end;
           (_Garbage) ->
               {error, failed_to_get_proxy_port}
       end).


do_remote_cluster(JsonGet, Cert) ->
    with_pools(
      JsonGet,
      fun (Pools, UUID) ->
              with_default_pool_details(
                Pools, JsonGet,
                fun (PoolDetails) ->
                        with_nodes(
                          PoolDetails, <<"default pool details">>,
                          [{<<"hostname">>, fun extract_string/2},
                           {<<"ports">>, fun extract_object/2}],
                          fun (NodeProps) ->
                                  Nodes = lists:map(fun props_to_remote_node/1,
                                                    NodeProps),
                                  SortedNodes = lists:sort(Nodes),

                                  {ok, #remote_cluster{uuid=UUID,
                                                       nodes=SortedNodes,
                                                       cert=Cert}}
                          end)
                end)
      end).

get_oldest_node_version(PoolNodeProps) ->
    lists:foldl(
      fun(NodeProps, Acc) ->
              case proplists:get_value(<<"version">>, NodeProps) of
                  undefined ->
                      [0, 0];
                  V ->
                      min(Acc, V)
              end
      end, [999, 0], PoolNodeProps).

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

extract_node_props(PropsExtractor, Context, NodeStruct) when is_function(PropsExtractor) ->
    PropsExtractor(NodeStruct, Context);
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

    RN = hostname_to_remote_node(binary_to_list(Hostname)),

    add_port_props(RN, proplists:get_value(<<"ports">>, Props)).

add_port_props(RemoteNode, PortProps) ->
    RemoteNode#remote_node{
      memcached_port = proplists:get_value(<<"direct">>, PortProps),
      ssl_proxy_port = proplists:get_value(<<"sslProxy">>, PortProps),
      https_port = proplists:get_value(<<"httpsMgmt">>, PortProps),
      https_capi_port = proplists:get_value(<<"httpsCAPI">>, PortProps)}.

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

remote_cluster_and_bucket(TargetNode, RemoteCluster,
                          BucketStr, Username, Password, ForceNewConnection) ->
    Bucket = list_to_binary(BucketStr),
    remote_bucket_from_node(TargetNode, Bucket, Username, Password,
                            RemoteCluster, ForceNewConnection).

remote_bucket_from_node(#remote_node{host=Host, port=Port, https_port = needed_but_unknown},
                        Bucket, Username, Password, RemoteCluster, ForceNewConnection) ->
    true = (RemoteCluster#remote_cluster.cert =/= undefined),
    case fetch_remote_node_record(Host, Port) of
        {ok, RemoteNode} ->
            remote_bucket_from_node(RemoteNode,
                                    Bucket, Username, Password,
                                    RemoteCluster, ForceNewConnection);
        Err ->
            Err
    end;
remote_bucket_from_node(RemoteNode, Bucket, Username, Password,
                        #remote_cluster{uuid = UUID, cert = Cert} = RemoteCluster,
                        ForceNewConnection) ->
    Creds = {Username, Password},

    {JsonGet, Scheme, Host, Port} = mk_json_get_for_node(RemoteNode, Cert,
                                                         Username, Password,
                                                         ForceNewConnection),

    with_pools(
      JsonGet,
      fun (Pools, ActualUUID) ->
              case ActualUUID =:= UUID of
                  true ->
                      with_default_pool_details(
                        Pools, JsonGet,
                        fun (PoolDetails) ->
                                remote_bucket_with_pool_details(PoolDetails,
                                                                RemoteCluster,
                                                                Bucket,
                                                                Creds, JsonGet)

                        end);
                  false ->
                      ?log_info("Attempted to get vbucket map for bucket `~s` "
                                "from remote node ~s://~s:~b. But cluster's "
                                "uuid (~s) does not match expected one (~s)",
                                [Bucket, Scheme, Host, Port, ActualUUID, UUID]),
                      {error, other_cluster,
                       <<"Remote cluster uuid doesn't match expected one.">>}
              end
      end).

remote_bucket_with_pool_details(PoolDetails, RemoteCluster, Bucket, Creds, JsonGet) ->
    with_nodes(
      PoolDetails, <<"default pool details">>,
      [{<<"hostname">>, fun extract_string/2},
       {<<"ports">>, fun extract_object/2},
       {<<"version">>, fun extract_version/2}],
      fun (PoolNodeProps) ->
              with_buckets(
                PoolDetails, JsonGet,
                fun (Buckets) ->
                        with_bucket(
                          Buckets, Bucket,
                          fun (BucketObject, BucketUUID) ->
                                  with_nodes(
                                    BucketObject, <<"bucket details">>,
                                    fun maybe_extract_important_buckets_props/2,
                                    fun (BucketNodeProps) ->
                                            remote_bucket_with_bucket(Bucket,
                                                                      BucketObject,
                                                                      RemoteCluster,
                                                                      BucketUUID,
                                                                      PoolNodeProps,
                                                                      BucketNodeProps,
                                                                      Creds)
                                    end)
                          end)
                end)
      end).

maybe_extract_important_buckets_props({struct, NodeKV}, Ctx) ->
    case proplists:get_value(<<"couchApiBase">>, NodeKV) of
        undefined ->
            ?log_debug("skipping node without couchApiBase: ~p", [NodeKV]),
            [];
        _ ->
            RV = extract_node_props([{<<"hostname">>, fun extract_string/2},
                                     {<<"couchApiBase">>, fun extract_string/2},
                                     {<<"ports">>, fun extract_object/2}],
                                    Ctx, {struct, NodeKV}),
            case RV of
                [Props] ->
                    case proplists:get_value(<<"couchApiBaseHTTPS">>, NodeKV) of
                        undefined ->
                            RV;
                        _ ->
                            case extract_node_props([{<<"couchApiBaseHTTPS">>, fun extract_string/2}],
                                                    Ctx, {struct, NodeKV}) of
                                [] ->
                                    RV;
                                [Props2] ->
                                    ?log_debug("extracted couchApiBaseHTTPS"),
                                    [Props2 ++ Props]
                            end
                    end;
                [] ->
                    RV
            end
    end;
maybe_extract_important_buckets_props(BadNodeStruct, Ctx) ->
    extract_node_props([], Ctx, BadNodeStruct).


remote_bucket_with_bucket(BucketName, BucketObject, OrigRemoteCluster,
                          BucketUUID, PoolNodeProps, BucketNodeProps, Creds) ->
    PoolNodes = lists:map(fun props_to_remote_node/1, PoolNodeProps),
    BucketNodes = lists:map(fun props_to_remote_node/1, BucketNodeProps),

    RemoteNodes = lists:usort(PoolNodes ++ BucketNodes),
    RemoteCluster = OrigRemoteCluster#remote_cluster{nodes=RemoteNodes},

    Version = get_oldest_node_version(PoolNodeProps),

    with_mcd_to_couch_uri_dict(
      BucketNodeProps, Creds, RemoteCluster#remote_cluster.cert,
      fun (McdToCouchDict) ->
              expect_nested_object(
                <<"vBucketServerMap">>, BucketObject, <<"bucket details">>,
                fun (VBucketServerMap) ->
                        expect_nested_string(
                          <<"saslPassword">>, BucketObject, <<"bucket password">>,
                          fun (Password) ->
                                  Caps = proplists:get_value(<<"bucketCapabilities">>, BucketObject),
                                  true = is_list(Caps),
                                  remote_bucket_with_server_map(BucketName, VBucketServerMap, BucketUUID,
                                                                RemoteCluster, RemoteNodes, McdToCouchDict,
                                                                Password, Version, Caps)
                          end)
                end)
      end).

remote_bucket_with_server_map(BucketName, ServerMap, BucketUUID,
                              RemoteCluster, RemoteNodes, McdToCouchDict,
                              Password, Version, Caps) ->
    with_remote_nodes_mapped_server_list(
      RemoteNodes, ServerMap,
      fun (ServerList, RemoteServers) ->
              IxToCouchDict = build_ix_to_couch_uri_dict(ServerList,
                                                         McdToCouchDict),
              expect_nested_array(
                <<"vBucketMap">>, ServerMap, <<"vbucket server map">>,
                fun (VBucketMap) ->
                        CAPIVBucketMapDict =
                            build_vbmap(VBucketMap,
                                        BucketUUID, IxToCouchDict),

                        #remote_cluster{uuid=ClusterUUID,
                                        cert=ClusterCert} = RemoteCluster,
                        RemoteBucket =
                            #remote_bucket{name=BucketName,
                                           uuid=BucketUUID,
                                           password=Password,
                                           cluster_uuid=ClusterUUID,
                                           cluster_cert=ClusterCert,
                                           server_list_nodes=RemoteServers,
                                           bucket_caps = Caps,
                                           raw_vbucket_map=dict:from_list(misc:enumerate(VBucketMap, 0)),
                                           capi_vbucket_map=CAPIVBucketMapDict,
                                           cluster_version=Version},

                        {ok, {RemoteCluster, RemoteBucket}}
                end)
      end).

with_remote_nodes_mapped_server_list(RemoteNodes, ServerMap, K) ->
    with_server_list(
      ServerMap,
      fun (ServerList) ->
              RH = [{iolist_to_binary([H, ":", integer_to_list(P)]), R} || #remote_node{host = H, memcached_port = P} = R <- RemoteNodes],
              Mapped = [case lists:keyfind(Hostname, 1, RH) of
                            false ->
                                ?log_debug("Could not find: ~p in ~p", [Hostname, RH]),
                                error;
                            {_, R} -> R
                        end || Hostname <- ServerList],
              case lists:member(error, Mapped) of
                  true ->
                      {error, bad_value, <<"server list doesn't match nodes list">>};
                  _ ->
                      K(ServerList, Mapped)
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
    [NodeIxRaw | _Rest] = Chain,
    expect_number(
      NodeIxRaw, <<"Vbucket map chain">>,
      fun (NodeIx) ->
              case NodeIx of
                  -1 ->
                      {ok, [undefined]};
                  _ ->
                      case dict:find(NodeIx, IxToCouchDict) of
                          error ->
                              Msg = io_lib:format("Invalid node reference in "
                                                  "vbucket map chain: ~p", [NodeIx]),
                              ?log_error("~s", [Msg]),
                              {error, bad_value, iolist_to_binary(Msg)};
                          {ok, none} ->
                              Msg = io_lib:format("Invalid node reference in "
                                                  "vbucket map chain: ~p. "
                                                  "Found node without couchApiBase in active vbucket map position", [NodeIx]),
                              ?log_error("~s", [Msg]),
                              {error, bad_value, iolist_to_binary(Msg)};
                          {ok, URL} ->
                              VBucketURL0 = [URL, "%2f", integer_to_list(VBucket),
                                             "%3b", BucketUUID],
                              VBucketURL = iolist_to_binary(VBucketURL0),
                              {ok, [VBucketURL]}
                      end
              end
      end).

build_ix_to_couch_uri_dict(ServerList, McdToCouchDict) ->
    do_build_ix_to_couch_uri_dict(ServerList, McdToCouchDict, 0, dict:new()).

do_build_ix_to_couch_uri_dict([], _McdToCouchDict, _Ix, D) ->
    D;
do_build_ix_to_couch_uri_dict([S | Rest], McdToCouchDict, Ix, D) ->
    case dict:find(S, McdToCouchDict) of
        error ->
            ?log_debug("Was not able to find node corresponding to server ~s. Assuming it's couchApiBase-less node", [S]),

            D1 = dict:store(Ix, none, D),
            do_build_ix_to_couch_uri_dict(Rest, McdToCouchDict, Ix + 1, D1);
        {ok, Value} ->
            D1 = dict:store(Ix, Value, D),
            do_build_ix_to_couch_uri_dict(Rest, McdToCouchDict, Ix + 1, D1)
    end.

with_mcd_to_couch_uri_dict(NodeProps, Creds, Cert, K) ->
    do_with_mcd_to_couch_uri_dict(NodeProps, dict:new(), Creds, Cert, K).

do_with_mcd_to_couch_uri_dict([], Dict, _Creds, _Cert, K) ->
    K(Dict);
do_with_mcd_to_couch_uri_dict([Props | Rest], Dict, Creds, Cert, K) ->
    Hostname = proplists:get_value(<<"hostname">>, Props),
    CouchApiBase0 = case Cert of
                        undefined ->
                            ?log_debug("Going to pick plain couchApiBase for mcd_to_couch_uri_dict: ~p", [proplists:get_value(<<"couchApiBase">>, Props)]),
                            proplists:get_value(<<"couchApiBase">>, Props);
                        _ ->
                            ?log_debug("Going to pick couchApiBaseHTTPS for mcd_to_couch_uri_dict: ~p", [proplists:get_value(<<"couchApiBaseHTTPS">>, Props)]),
                            proplists:get_value(<<"couchApiBaseHTTPS">>, Props)
                    end,
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

              do_with_mcd_to_couch_uri_dict(Rest, NewDict, Creds, Cert, K)
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

mk_json_get_for_node(#remote_node{host = Host,
                                  port = Port,
                                  https_port = SPort},
                     Cert, Username, Password, ForceNewConnection) ->
    case Cert =/= undefined of
        true ->
            OptionsOverride = case ForceNewConnection of
                                  true ->
                                      [{pool, ns_null_connection_pool},
                                       {connect_options, [{reuse_sessions, false}]}];
                                  false ->
                                      []
                              end,
            {mk_ssl_json_get(Host, SPort, Username, Password, Cert, OptionsOverride),
             "https", Host, SPort};
        _ ->
            OptionsOverride = case ForceNewConnection of
                                  true ->
                                      [{pool, ns_null_connection_pool}];
                                  false ->
                                      []
                              end,
            %% TODO: this doesn't hold right now
            %% undefined = SPort,
            {mk_plain_json_get(Host, Port, Username, Password, OptionsOverride), "http", Host, Port}
    end.

mk_ssl_json_get(Host, Port, Username, Password, CertPEM, HttpOptionsOverride) ->
    Options0 = HttpOptionsOverride ++ [{connect_timeout, 30000},
                                       {timeout, 60000},
                                       {pool, xdc_lhttpc_pool}],
    Options =
        case CertPEM of
            <<"-">> ->
                Options0;
            _ ->
                ConnectOptions0 = proplists:get_value(connect_options, Options0, []),

                ConnectOptions = ns_ssl:cert_pem_to_ssl_verify_options(CertPEM)
                    ++ ConnectOptions0,
                [{connect_options, ConnectOptions}
                 | lists:keydelete(connect_options, 1, Options0)]
        end,
    do_mk_json_get(Host, Port, Options, "https", Username, Password).

mk_plain_json_get(Host, Port, Username, Password, HttpOptionsOverride) ->
    Options = HttpOptionsOverride ++ [{connect_timeout, 30000},
                                      {timeout, 60000},
                                      {pool, xdc_lhttpc_pool}],
    do_mk_json_get(Host, Port, Options, "http", Username, Password).

do_mk_json_get(Host, Port, Options, Scheme, Username, Password) ->
    fun (Path, K) ->
            URL = menelaus_rest:rest_url(Host, Port, Path, Scheme),
            ?log_debug("Doing get of ~s", [URL]),
            R = menelaus_rest:json_request_hilevel(get,
                                                   {URL, {Host, Port, Path}},
                                                   {Username, Password},
                                                   Options),

            case R of
                {ok, Value} ->
                    K(Value);
                {client_error, Body} ->
                    ?log_error("Request to ~s://~s:****@~s:~b~s returned "
                               "400 status code:~n~p",
                               [Scheme, mochiweb_util:quote_plus(Username),
                                Host, Port, Path, Body]),

                    %% convert it to the same form as all other errors
                    {error, client_error,
                     <<"Remote cluster returned 400 status code unexpectedly">>};
                Error ->
                    ?log_error("Request to ~s://~s:****@~s:~b~s failed:~n~p",
                               [Scheme, mochiweb_util:quote_plus(Username),
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
            not(lists:member(Hostname, [remote_node_to_hostname(RN) || RN <- Nodes]))
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
                                     "to ~p because old one (~p) is not part of "
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
