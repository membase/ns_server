%% @author Membase <info@membase.com>
%% @copyright 2011 Membase, Inc.
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
%%
%% @doc keeps recent hot keys for easy access
%%
-module(moxi_stats_collector).

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0, fetch_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {main_socket,
                per_port_sockets::dict()}).

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
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

fetch_stats(BucketName) ->
    gen_server:call(?MODULE, {fetch_stats, BucketName}).

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
    proc_lib:init_ack({ok, self()}),
    Config = ns_config:get(),
    MainSocket = connect_main(Config),
    State = #state{main_socket = MainSocket,
                   per_port_sockets = dict:new()},
    gen_server:enter_loop(?MODULE, [], State).

connect_moxi(Port) ->
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {packet, 0},
                                                  {active, false}]),
    S.

connect_main(Config) ->
    Port = ns_config:search_node_prop(Config, moxi, port),
    Socket = connect_moxi(Port),
    Socket.

bucket_port_map(_State) ->
    dict:from_list([{N, proplists:get_value(moxi_port, PS)}
                    || {N, PS} <- ns_bucket:get_buckets()]).

interesting_stat_p(Bin) ->
    BinSize = bit_size(Bin)-160,
    case Bin of
        <<_:BinSize, ":tot_local_cmd_count">> ->
            160 = bit_size(<<":tot_local_cmd_count">>),
            <<"proxy_local_cmd_count">>;
        <<_:BinSize, _:(160-152), ":tot_local_cmd_time">> ->
            152 = bit_size(<<":tot_local_cmd_time">>),
            <<"proxy_local_cmd_time">>;
        <<_:BinSize, _:(160-112), ":tot_cmd_count">> ->
            112 = bit_size(<<":tot_cmd_count">>),
            <<"proxy_cmd_count">>;
        <<_:BinSize, _:(160-104), ":tot_cmd_time">> ->
            104 = bit_size(<<":tot_cmd_time">>),
            <<"proxy_cmd_time">>;
        _ -> undefined
    end.

-spec extract_stat_bucket(binary()) -> binary() | undefined.
extract_stat_bucket(K) ->
    %% K looks like this: 11211:default:pstd_stats_cmd:quiet_unl:cas
    case misc:split_binary_at_char(K, $:) of
        {_, After} ->
            case misc:split_binary_at_char(After, $:) of
                {BucketName, _} ->
                    BucketName;
                _ -> undefined
            end;
        _ -> undefined
    end.

-spec stats_foldl_er(binary(), binary(),
                     [{binary(), [{binary(), binary()}]}])
                    -> [{binary(), [{binary(), binary()}]}].
stats_foldl_er(K, V, Acc) ->
    case interesting_stat_p(K) of
        undefined -> Acc;
        StatName ->
            BucketName = extract_stat_bucket(K),
            true = is_binary(BucketName),
            case Acc of
                [{BucketName, CurrentStats} | RestStats] ->
                    NewCurrentStats = [{StatName, V} | CurrentStats],
                    [{BucketName, NewCurrentStats} | RestStats];
                _ ->
                    NewCurrentStats = [{StatName, V}],
                    [{BucketName, NewCurrentStats} | Acc]
            end
    end.

-spec do_grab_stats(port()) -> {ok, [{string(), [{atom(), binary()}]}]} | mc_error().
do_grab_stats(Sock) ->
    case mc_client_binary:stats(Sock, <<"proxy buckets">>,
                                fun stats_foldl_er/3, []) of
        {ok, Stats} ->
            {ok, [{binary_to_list(K), V} || {K,V} <- Stats]};
        X -> X
    end.

fetch_main_stats(State) ->
    {ok, RawStats} = do_grab_stats(State#state.main_socket),
    RawStats.

grab_per_port_stats(State, BucketName, Port) ->
    {Sock, NewState}
        = case dict:find(Port, State#state.per_port_sockets) of
              {ok, X} -> {X, State};
              error ->
                  S = connect_moxi(Port),
                  {S, State#state{per_port_sockets =
                                      dict:store(Port, S,
                                                 State#state.per_port_sockets)}}
          end,
    {ok, [{BucketName, Stats}]} = do_grab_stats(Sock),
    {Stats, NewState}.

cleanup_per_port_sockets(BucketPortMap, State) ->
    NeededPorts = sets:from_list(
                    lists:foldl(fun ({_, undefined}, Acc) ->
                                        Acc;
                                    ({_, Port}, Acc) ->
                                        [Port | Acc]
                                end, [], dict:to_list(BucketPortMap))),
    UsedPorts = sets:from_list(dict:fetch_keys(State#state.per_port_sockets)),
    NewDict = sets:fold(fun (Port, Dict) ->
                                Socket = dict:fetch(Port, Dict),
                                ok = gen_tcp:close(Socket),
                                dict:erase(Port, Dict)
                        end, State#state.per_port_sockets,
                        sets:subtract(UsedPorts, NeededPorts)),
    State#state{per_port_sockets = NewDict}.

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
handle_call({fetch_stats, BucketName}, _From, State) ->
    BucketPortMap = bucket_port_map(State),
    Port = dict:fetch(BucketName, BucketPortMap),
    {Reply, State2} =
        case Port of
            undefined ->
                AllStats = fetch_main_stats(State),
                {_, BucketStats} = lists:keyfind(BucketName, 1, AllStats),
                {BucketStats, State};
            _ ->
                grab_per_port_stats(State, BucketName, Port)
        end,
    State3 = cleanup_per_port_sockets(BucketPortMap, State2),
    {reply, Reply, State3};
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


-ifdef(EUNIT).

stats_parsing_test() ->
    Pairs =
        [{<<"12001:default:stats:listening">>, <<"2">>},
         {<<"12001:default:stats:listening_failed">>, <<"0">>},
         {<<"12001:default:pstd_stats:num_upstream">>, <<"2">>},
         {<<"12001:default:pstd_stats:tot_upstream">>, <<"20">>},
         {<<"12001:default:pstd_stats:num_downstream_conn">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_conn">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_conn_acquired">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_downstream_conn_released">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_downstream_released">>, <<"42769">>},
         {<<"12001:default:pstd_stats:tot_downstream_reserved">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_downstream_reserved_time">>, <<"0">>},
         {<<"12001:default:pstd_stats:max_downstream_reserved_time">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_freed">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_quit_server">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_max_reached">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_create_failed">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect_started">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect_wait">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect_failed">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect_timeout">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect_interval">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_connect_max_reached">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_waiting_errors">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_auth">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_auth_failed">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_bucket">>, <<"16">>},
         {<<"12001:default:pstd_stats:tot_downstream_bucket_failed">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_propagate_failed">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_close_on_upstream_close">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_conn_queue_timeout">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_conn_queue_add">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_conn_queue_remove">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_downstream_timeout">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_wait_queue_timeout">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_auth_timeout">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_assign_downstream">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_assign_upstream">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_assign_recursion">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_reset_upstream_avail">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_multiget_keys">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_multiget_keys_dedupe">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_multiget_bytes_dedupe">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_optimize_sets">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_retry">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_retry_time">>, <<"0">>},
         {<<"12001:default:pstd_stats:max_retry_time">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_retry_vbucket">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_upstream_paused">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_upstream_unpaused">>, <<"42753">>},
         {<<"12001:default:pstd_stats:err_oom">>, <<"0">>},
         {<<"12001:default:pstd_stats:err_upstream_write_prep">>, <<"0">>},
         {<<"12001:default:pstd_stats:err_downstream_write_prep">>, <<"0">>},
         {<<"12001:default:pstd_stats:tot_cmd_time">>, <<"19416352">>},
         {<<"12001:default:pstd_stats:tot_cmd_count">>, <<"42753">>},
         {<<"12001:default:pstd_stats:tot_local_cmd_time">>, <<"19416352">>},
         {<<"12001:default:pstd_stats:tot_local_cmd_count">>, <<"42753">>},
         {<<"12001:default:pstd_stats_cmd:regular_get:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get_key:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get_key:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get_key:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get_key:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get_key:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_get_key:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_set:seen">>, <<"42753">>},
         {<<"12001:default:pstd_stats_cmd:regular_set:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_set:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_set:read_bytes">>, <<"6353160">>},
         {<<"12001:default:pstd_stats_cmd:regular_set:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_set:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_add:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_add:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_add:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_add:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_add:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_add:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_replace:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_replace:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_replace:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_replace:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_replace:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_replace:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_delete:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_delete:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_delete:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_delete:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_delete:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_delete:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_append:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_append:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_append:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_append:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_append:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_append:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_prepend:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_prepend:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_prepend:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_prepend:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_prepend:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_prepend:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_incr:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_incr:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_incr:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_incr:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_incr:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_incr:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_decr:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_decr:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_decr:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_decr:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_decr:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_decr:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_flush_all:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_flush_all:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_flush_all:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_flush_all:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_flush_all:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_flush_all:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_cas:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_cas:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_cas:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_cas:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_cas:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_cas:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats_reset:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats_reset:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats_reset:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats_reset:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats_reset:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_stats_reset:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_version:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_version:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_version:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_version:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_version:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_version:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_verbosity:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_verbosity:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_verbosity:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_verbosity:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_verbosity:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_verbosity:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_quit:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_quit:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_quit:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_quit:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_quit:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_quit:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_getl:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_getl:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_getl:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_getl:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_getl:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_getl:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_unl:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_unl:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_unl:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_unl:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_unl:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_unl:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_ERROR:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_ERROR:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_ERROR:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_ERROR:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_ERROR:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:regular_ERROR:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get_key:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get_key:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get_key:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get_key:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get_key:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_get_key:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_set:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_set:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_set:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_set:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_set:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_set:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_add:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_add:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_add:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_add:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_add:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_add:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_replace:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_replace:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_replace:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_replace:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_replace:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_replace:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_delete:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_delete:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_delete:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_delete:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_delete:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_delete:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_append:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_append:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_append:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_append:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_append:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_append:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_prepend:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_prepend:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_prepend:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_prepend:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_prepend:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_prepend:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_incr:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_incr:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_incr:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_incr:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_incr:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_incr:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_decr:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_decr:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_decr:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_decr:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_decr:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_decr:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_flush_all:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_flush_all:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_flush_all:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_flush_all:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_flush_all:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_flush_all:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_cas:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_cas:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_cas:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_cas:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_cas:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_cas:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats_reset:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats_reset:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats_reset:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats_reset:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats_reset:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_stats_reset:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_version:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_version:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_version:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_version:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_version:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_version:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_verbosity:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_verbosity:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_verbosity:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_verbosity:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_verbosity:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_verbosity:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_quit:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_quit:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_quit:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_quit:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_quit:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_quit:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_getl:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_getl:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_getl:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_getl:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_getl:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_getl:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_unl:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_unl:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_unl:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_unl:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_unl:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_unl:cas">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_ERROR:seen">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_ERROR:hits">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_ERROR:misses">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_ERROR:read_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_ERROR:write_bytes">>, <<"0">>},
         {<<"12001:default:pstd_stats_cmd:quiet_ERROR:cas">>, <<"0">>}],
    Result = lists:foldl(fun ({K, V}, Acc) ->
                                 stats_foldl_er(K, V, Acc)
                         end, [], Pairs),
    ?assertMatch([{<<"default">>, _}], Result),
    [{<<"default">>, DefaultStats}] = Result,
    ?assertEqual(lists:sort([{<<"proxy_local_cmd_count">>, <<"42753">>},
                             {<<"proxy_local_cmd_time">>, <<"19416352">>},
                             {<<"proxy_cmd_count">>, <<"42753">>},
                             {<<"proxy_cmd_time">>, <<"19416352">>}]),
                 lists:sort(DefaultStats)).

-endif.
