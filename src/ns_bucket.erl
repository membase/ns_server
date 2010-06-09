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
-export([get_buckets/0, create_bucket/1]).

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

get_buckets() ->
    Config = ns_config:get(),
    ns_config:search_prop(Config, memcached, buckets, []).

create_bucket(Bucket) ->
    Buckets = get_buckets(),
    case lists:member(Bucket, Buckets) of
        true ->
            {error, already_exists};
        false ->
            ns_config:set(memcached, buckets, [Bucket|Buckets])
    end.


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
    check_config(),
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
    Buckets = get_buckets(),
    {ok, CurBuckets} = ns_memcached:list_buckets(),
    MissingBuckets = lists:filter(
                       fun (Bucket) ->
                               not lists:member(Bucket, CurBuckets)
                       end, Buckets),
    case MissingBuckets of
        [] -> ok;
        _ ->
            error_logger:info_msg("~p:check_config(): creating missing buckets: ~p~n",
                                  [?MODULE, MissingBuckets]),
            lists:foreach(fun create_missing_bucket/1, MissingBuckets)
    end.

create_missing_bucket(Bucket) ->
    DbName = get_dbname(Bucket),
    ns_memcached:create_bucket(Bucket, "dbname=" ++ DbName).

get_dbname(Bucket) ->
    DataDir = filename:join(ns_config_default:default_path("data"), misc:node_name_short()),
    DbName = filename:join(DataDir, Bucket),
    error_logger:info_msg("built DbName ~p~n", [DbName]),
    ok = filelib:ensure_dir(DbName),
    DbName.

