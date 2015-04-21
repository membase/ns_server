%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
-module(memcached_config_mgr).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0]).

-export([expand_memcached_config/2]).

%% referenced from ns_config_default
-export([get_minidump_dir/2, omit_missing_mcd_ports/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-record(state, {
          port_pid :: pid(),
          memcached_config :: binary()
         }).

init([]) ->
    proc_lib:init_ack({ok, self()}),
    ?log_debug("waiting for completion of initial ns_ports_setup round"),
    ns_ports_setup:sync(),
    ?log_debug("ns_ports_setup seems to be ready"),
    Pid = find_port_pid_loop(100, 250),
    remote_monitors:monitor(Pid),
    Config = ns_config:get(),
    WantedMcdConfig = memcached_config(Config),
    ReadConfigResult = read_current_memcached_config(Pid),
    McdConfig  = case ReadConfigResult of
                     inactive ->
                         WantedMcdConfig;
                     {active, XMcdConfig} ->
                         XMcdConfig
                 end,
    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events,
                             fun ({Key, _}) ->
                                     case is_notable_config_key(Key) of
                                         true ->
                                             Self ! do_check;
                                         _ ->
                                             []
                                     end;
                                 (_Other) ->
                                     []
                             end),
    Self ! do_check,
    ActualMcdConfig =
        case ReadConfigResult of
            inactive ->
                delete_prev_config_file(),
                McdConfigPath = get_memcached_config_path(),
                ok = misc:atomic_write_file(McdConfigPath, WantedMcdConfig),
                ?log_debug("wrote memcached config to ~s. Will activate memcached port server",
                           [McdConfigPath]),
                ok = ns_port_server:activate(Pid),
                ?log_debug("activated memcached port server"),
                WantedMcdConfig;
            _ ->
                ?log_debug("found memcached port to be already active"),
                McdConfig
    end,
    State = #state{port_pid = Pid,
                   memcached_config = ActualMcdConfig},
    gen_server:enter_loop(?MODULE, [], State).

delete_prev_config_file() ->
    PrevMcdConfigPath = get_memcached_config_path() ++ ".prev",
    case file:delete(PrevMcdConfigPath) of
        ok -> ok;
        {error, enoent} -> ok;
        Other ->
            ?log_error("failed to delete ~s: ~p", [PrevMcdConfigPath, Other]),
            erlang:error({failed_to_delete_prev_config, Other})
    end.

is_notable_config_key({node, N, memcached}) ->
    N =:= node();
is_notable_config_key({node, N, memcached_defaults}) ->
    N =:= node();
is_notable_config_key({node, N, memcached_config}) ->
    N =:= node();
is_notable_config_key({node, N, memcached_config_extra}) ->
    N =:= node();
is_notable_config_key(memcached) -> true;
is_notable_config_key(memcached_config_extra) -> true;
is_notable_config_key(_) ->
    false.

find_port_pid_loop(Tries, Delay) when Tries > 0 ->
    RV = rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, find_port, [memcached]),
    case RV of
        Pid when is_pid(Pid) ->
            supervisor_cushion:child_pid(Pid);
        Other ->
            ?log_debug("Failed to obtain memcached port pid (~p). Will retry", [Other]),
            timer:sleep(Delay),
            find_port_pid_loop(Tries - 1, Delay)
    end.

handle_call(_, _From, _State) ->
    erlang:error(unsupported).

handle_cast(_, _State) ->
    erlang:error(unsupported).

handle_info(do_check, #state{memcached_config = CurrentMcdConfig} = State) ->
    Config = ns_config:get(),
    case memcached_config(Config) of
        %% NOTE: CurrentMcdConfig is bound above
        CurrentMcdConfig ->
            {noreply, State};
        DifferentConfig ->
            apply_changed_memcached_config(DifferentConfig, State)
    end;
handle_info({remote_monitor_down, Pid, Reason}, #state{port_pid = Pid} = State) ->
    ?log_debug("Got DOWN with reason: ~p from memcached port server: ~p. Shutting down", [Reason, Pid]),
    {stop, {shutdown, {memcached_port_server_down, Pid, Reason}}, State};
handle_info(Other, State) ->
    ?log_debug("Got unknown message: ~p", [Other]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

apply_changed_memcached_config(DifferentConfig, State) ->
    case ns_memcached:config_validate(DifferentConfig) of
        ok ->
            ?log_debug("New memcached config is hot-reloadable."),
            hot_reload_config(DifferentConfig, State, 10, []),
            {noreply, State#state{memcached_config = DifferentConfig}};
        {memcached_error, einval, _} ->
            ?log_debug("Memcached config is not hot-reloadable"),
            RestartMemcached = case ns_config:search_node(node(),
                                                          ns_config:latest_config_marker(),
                                                          auto_restart_memcached) of
                                   {value, RestartMemcachedBool} ->
                                       true = is_boolean(RestartMemcachedBool),
                                       RestartMemcachedBool;
                                   _ -> false
                               end,
            ale:info(?USER_LOGGER, "Got memcached.json config change that's not hot-reloadable. Changed keys: ~p",
                     [changed_keys(State#state.memcached_config, DifferentConfig)]),
            case RestartMemcached of
                false ->
                    ?log_debug("will not restart memcached because new config is not hot-reloadable and auto_restart_memcached is not enabled"),
                    {noreply, State};
                _ ->
                    ?log_debug("will auto-restart memcached"),
                    ok = ns_ports_setup:restart_memcached(),
                    ale:info(?USER_LOGGER, "auto-restarted memcached for config change"),
                    {stop, {shutdown, restarting_memcached}, State}
            end
    end.

changed_keys(BlobBefore, BlobAfter) ->
    try
        {Before0} = ejson:decode(BlobBefore),
        {After0} = ejson:decode(BlobAfter),
        Before = lists:sort(Before0),
        After = lists:sort(After0),
        Diffing = (Before -- After) ++ (After -- Before),
        lists:usort([K || {K, _} <- Diffing])
    catch _:_ ->
            unknown
    end.

hot_reload_config(NewMcdConfig, State, Tries, LastErr) when Tries < 1 ->
    ale:error(?USER_LOGGER, "Unable to apply memcached config update that was supposed to succeed. Error: ~p."
              " Giving up. Restart memcached to apply that config change. Updated keys: ~p",
              [LastErr, changed_keys(State#state.memcached_config, NewMcdConfig)]);
hot_reload_config(NewMcdConfig, State, Tries, _LastErr) ->
    FilePath = get_memcached_config_path(),
    PrevFilePath = FilePath ++ ".prev",

    %% lets double check everything
    {active, CurrentMcdConfig} = read_current_memcached_config(State#state.port_pid),
    true = (CurrentMcdConfig =:= State#state.memcached_config),

    %% now we save currently active config to .prev
    ok = misc:atomic_write_file(PrevFilePath, CurrentMcdConfig),
    %% if we crash here, .prev has copy of active memcached config and
    %% we'll be able to retry hot or cold config update
    ok = misc:atomic_write_file(FilePath, NewMcdConfig),

    case ns_memcached:config_reload() of
        ok ->
            delete_prev_config_file(),
            ale:info(?USER_LOGGER, "Hot-reloaded memcached.json for config change of the following keys: ~p",
                     [changed_keys(CurrentMcdConfig, NewMcdConfig)]),
            ok;
        Err ->
            ?log_error("Failed to reload memcached config. Will retry. Error: ~p", [Err]),
            timer:sleep(1000),
            hot_reload_config(NewMcdConfig, State, Tries - 1, Err)
    end.

get_memcached_config_path() ->
    Path = ns_config:search_node_prop(ns_config:latest_config_marker(), memcached, config_path),
    true = is_list(Path),
    Path.

read_current_memcached_config(McdPortServer) ->
    case ns_port_server:is_active(McdPortServer) of
        true ->
            FilePath = get_memcached_config_path(),
            PrevFilePath = FilePath ++ ".prev",
            {ok, Contents} = do_read_current_memcached_config([PrevFilePath, FilePath]),
            {active, Contents};
        false ->
            inactive
    end.

do_read_current_memcached_config([]) ->
    ?log_debug("Failed to read any memcached config. Assuming it does not exist"),
    missing;
do_read_current_memcached_config([Path | Rest]) ->
    case file:read_file(Path) of
        {ok, Contents} ->
            {ok, Contents};
        {error, Error} ->
            ?log_debug("Got ~p while trying to read active memcached config from ~s", [Error, Path]),
            do_read_current_memcached_config(Rest)
    end.

memcached_config(Config) ->
    {value, McdParams0} = ns_config:search(Config, {node, node(), memcached}),
    {value, McdConf} = ns_config:search(Config, {node, node(), memcached_config}),

    GlobalMcdParams = ns_config:search(Config, memcached, []),

    DefaultMcdParams = ns_config:search(Config, {node, node(), memcached_defaults}, []),

    McdParams = McdParams0 ++ GlobalMcdParams ++ DefaultMcdParams,

    {Props} = expand_memcached_config(McdConf, McdParams),
    ExtraProps = ns_config:search(Config, {node, node(), memcached_config_extra}, []),
    ExtraPropsG = ns_config:search(Config, memcached_config_extra, []),

    BinPrefix = filename:dirname(path_config:component_path(bin)),
    RootProp = [{root, list_to_binary(BinPrefix)}],

    %% removes duplicates of properties making sure that local
    %% memcached_config_extra props overwrite global extra props and
    %% that memcached_config props overwrite them both.
    FinalProps =
        lists:foldl(
          fun (List, Acc) ->
                  normalize_memcached_props(List, Acc)
          end, [], [ExtraPropsG, ExtraProps, RootProp, Props]),

    ejson:encode({lists:sort(FinalProps)}).

normalize_memcached_props([], Tail) -> Tail;
normalize_memcached_props([{Key, Value} | Rest], Tail) ->
    RestNormalized = normalize_memcached_props(Rest, Tail),
    [{Key, Value} | lists:keydelete(Key, 1, RestNormalized)].

expand_memcached_config({Props}, Params) when is_list(Props) ->
    {[{Key, expand_memcached_config(Value, Params)} || {Key, Value} <- Props]};
expand_memcached_config(Array, Params) when is_list(Array) ->
    [expand_memcached_config(Elem, Params) || Elem <- Array];
expand_memcached_config({M, F, A}, Params) ->
    M:F(A, Params);
expand_memcached_config({Fmt, Args}, Params) ->
    Args1 = [expand_memcached_config(A, Params) || A <- Args],
    iolist_to_binary(io_lib:format(Fmt, Args1));
expand_memcached_config(Param, Params)
  when is_atom(Param), Param =/= true, Param =/= false ->
    {Param, Value} = lists:keyfind(Param, 1, Params),
    Value;
expand_memcached_config(Verbatim, _Params) ->
    Verbatim.

get_minidump_dir([], Params) ->
    list_to_binary(proplists:get_value(breakpad_minidump_dir_path, Params,  proplists:get_value(log_path, Params))).

omit_missing_mcd_ports(Interfaces, MCDParams) ->
    Expanded = memcached_config_mgr:expand_memcached_config(Interfaces, MCDParams),
    [Obj || Obj <- Expanded,
            case Obj of
                {Props} ->
                    proplists:get_value(port, Props) =/= undefined
            end].
