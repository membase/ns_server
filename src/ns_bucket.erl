%%%-------------------------------------------------------------------
%%% @author Sean Lynch <sean@northscale.com>
%%% @copyright (C) 2010, NorthScale, Inc.
%%% @doc
%%% Manages bucket configs on each node.
%%% @end
%%% Created :  8 Jun 2010 by Sean Lynch <sean@northscale.com>
%%%-------------------------------------------------------------------
-module(ns_bucket).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([config/1,
         get_bucket/1,
         get_buckets/0,
         get_bucket_names/0,
         json_map/2,
         set_bucket_config/2,
         set_map/2,
         set_servers/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(CHECK_INTERVAL, 5000).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

config(Bucket) ->
    {ok, CurrentConfig} = get_bucket(Bucket),
    NumReplicas = proplists:get_value(num_replicas, CurrentConfig),
    NumVBuckets = proplists:get_value(num_vbuckets, CurrentConfig),
    Map = case proplists:get_value(map, CurrentConfig) of
              undefined -> lists:duplicate(NumVBuckets, lists:duplicate(NumReplicas+1, undefined));
              M -> M
          end,
    Servers = proplists:get_value(servers, CurrentConfig),
    {NumReplicas, NumVBuckets, Map, Servers}.

get_bucket(Bucket) ->
    BucketConfigs = get_buckets(),
    case lists:keysearch(Bucket, 1, BucketConfigs) of
        {value, {_, Config}} ->
            {ok, Config};
        false -> not_present
    end.

get_bucket_names() ->
    % The config just has the list of bucket names right now.
    BucketConfigs = get_buckets(),
    proplists:get_keys(BucketConfigs).

get_buckets() ->
    Config = ns_config:get(),
    ns_config:search_prop(Config, buckets, configs, []).

json_map(BucketId, LocalAddr) ->
    Config = ns_config:get(),
    {NumReplicas, _, EMap, _} = config(BucketId),
    ENodes = lists:delete(undefined, lists:usort(lists:append(EMap))),
    Servers = lists:map(fun (ENode) ->
                                Port = ns_config:search_node_prop(ENode, Config, memcached, port),
                                Host = case misc:node_name_host(ENode) of
                                           {_Name, "127.0.0.1"} -> LocalAddr;
                                           {_Name, H} -> H
                                       end,
                                list_to_binary(Host ++ ":" ++ integer_to_list(Port))
                        end, ENodes),
    Map = lists:map(fun (Chain) ->
                            lists:map(fun (undefined) -> -1;
                                          (N) -> misc:position(N, ENodes) - 1
                                      end, Chain)
                    end, EMap),
    {struct, [{hashAlgorithm, <<"CRC">>},
              {numReplicas, NumReplicas},
              {serverList, Servers},
              {vBucketMap, Map}]}.

set_bucket_config(Bucket, NewConfig) ->
    update_bucket_config(Bucket, fun (_) -> NewConfig end).

set_map(Bucket, Map) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(map, 1, OldConfig, {map, Map})
      end).

set_servers(Bucket, Servers) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(servers, 1, OldConfig, {servers, Servers})
      end).

% Update the bucket config atomically.
update_bucket_config(Bucket, Fun) ->
    ok = ns_config:update(
      fun ({buckets, List}) ->
              Buckets = proplists:get_value(configs, List, []),
              OldConfig = proplists:get_value(Bucket, Buckets),
              NewConfig = Fun(OldConfig),
              NewBuckets = lists:keyreplace(Bucket, 1, Buckets, {Bucket, NewConfig}),
              {buckets, lists:keyreplace(configs, 1, List, {configs, NewBuckets})};
          (Pair) -> Pair
      end, make_ref()).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    timer:send_interval(?CHECK_INTERVAL, check_config),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(check_config, State) ->
    try check_config()
    catch
        E:R ->
            error_logger:info_msg("~p could not check config because of ~p~n",
                                  [?MODULE, {E, R}])
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Check the current config against the list of buckets on this server.
check_config() ->
    BucketConfigs = get_buckets(),
    case ns_memcached:list_buckets() of
        {ok, CurBuckets} ->
            lists:foreach(
              fun ({BucketName, BucketConfig}) ->
                      case lists:member(BucketName, CurBuckets) of
                          true -> ok;
                          false ->
                              ConfigString = config_string(BucketName, BucketConfig),
                              error_logger:info_msg(
                                "~p:check_config(): activating bucket ~p with config ~p~n",
                                [?MODULE, BucketName, ConfigString]),
                              ns_memcached:create_bucket(BucketName, ConfigString)
                      end
              end, BucketConfigs);
        _ -> ok
    end.

config_string(BucketName, BucketConfig) ->
    DbName = case proplists:get_value(dbname, BucketConfig) of
                 undefined ->
                     DataDir = filename:join(ns_config_default:default_path("data"),
                                             misc:node_name_short()),
                     filename:join(DataDir, BucketName);
                 N -> N
             end,
    ok = filelib:ensure_dir(DbName),
    lists:flatten(io_lib:format("vb0=false;dbname=~s", [DbName])).
