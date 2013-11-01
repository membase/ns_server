% Copyright (c) 2009, NorthScale, Inc.
% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
%
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% * Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
% * Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
% * Neither the name of Powerset, Inc nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
% COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(ns_config).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

-define(DEFAULT_TIMEOUT, 15000).
-define(TERMINATE_SAVE_TIMEOUT, 10000).

%% log codes
-define(RELOAD_FAILED, 1).
-define(RESAVE_FAILED, 2).
-define(CONFIG_CONFLICT, 3).
-define(GOT_TERMINATE_SAVE_TIMEOUT, 4).

-export([eval/1,
         start_link/2, start_link/1,
         merge/1,
         get/2, get/1, get/0, set/2, set/1,
         cas_config/2,
         set_initial/2, update/2, update_key/2, update_key/3,
         update_sub_key/3, set_sub/2, set_sub/3,
         search_node/3, search_node/2, search_node/1,
         search_node_prop/3, search_node_prop/4,
         search_node_prop/5,
         search/3, search/2, search/1,
         search_prop/3, search_prop/4,
         search_prop_tuple/3, search_prop_tuple/4,
         search_raw/2,
         search_with_vclock/2,
         run_txn/1,
         clear/0, clear/1,
         proplist_get_value/3,
         merge_kv_pairs/2,
         sync_announcements/0, get_kv_list/0, get_kv_list/1,
         upgrade_config_explicitly/1, config_version_token/0,
         fold/3]).

-export([save_config_sync/1]).

% Exported for tests only
-export([save_file/3, load_config/3,
         load_file/2, save_config_sync/2, send_config/2]).

% A static config file is often hand edited.
% potentially with in-line manual comments.
%
% A dynamic config file is system generated and modified,
% such as due to changes from UI/admin-screen operations, or
% nodes getting added/removed, and gossiping about config
% information.
%
-include("ns_config.hrl").

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([stop/0, resave/0, reannounce/0, replace/1]).

%% state sanitization
-export([format_status/2]).

format_status(_Opt, [_PDict, State]) ->
    ns_config_log:sanitize(State).

%% API

eval(Fun) ->
    gen_server:call(?MODULE, {eval, Fun}, ?DEFAULT_TIMEOUT).

start_link(Full) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Full, []).

start_link(ConfigPath, PolicyMod) -> start_link([ConfigPath, PolicyMod]).

stop()       -> gen_server:cast(?MODULE, stop).
resave()     -> gen_server:call(?MODULE, resave).
reannounce() -> gen_server:call(?MODULE, reannounce).

% ----------------------------------------

% Set & get configuration KVList, or [{Key, Val}*].
%
% ----------------------------------------

%% Merge another config rather than replacing ours
merge(KVList) ->
    gen_server:call(?MODULE, {merge, KVList}).

%% Set a value that will be overridden by any merged config
set_initial(Key, Value) ->
    ok = update_with_changes(fun (Config) ->
                                     NewPair = {Key, Value},
                                     {[NewPair], [NewPair | lists:keydelete(Key, 1, Config)]}
                             end).

update_config_key_rec(Key, Value, Rest, AccList) ->
    case Rest of
        [{Key, OldValue} = OldPair | XX] ->
            NewPair = case strip_metadata(OldValue) =:= strip_metadata(Value) of
                          true ->
                              OldPair;
                          _ ->
                              {Key, increment_vclock(Value, OldValue)}
                      end,
            [NewPair | lists:reverse(AccList, XX)];
        [Pair | XX2] ->
            update_config_key_rec(Key, Value, XX2, [Pair | AccList]);
        [] ->
            none
    end.

%% updates KVList with {Key, Value}. Places new tuple at the beginning
%% of list and removes old version for rest of list
update_config_key(Key, Value, KVList) ->
    case update_config_key_rec(Key, Value, KVList, []) of
        none -> [{Key, increment_vclock(Value, Value)} | KVList];
        NewList -> NewList
    end.

%% Replaces config key-value pairs by NewConfig if they're still equal
%% to OldConfig. Returns true on success.
cas_config(NewConfig, OldConfig) ->
    gen_server:call(?MODULE, {cas_config, NewConfig, OldConfig}).

set(Key, Value) ->
    ok = update_with_changes(fun (Config) ->
                                     NewList = update_config_key(Key, Value, Config),
                                     {[hd(NewList)], NewList}
                             end).

%% gets current config. Runs Body on it to get new config, then tries
%% to cas new config returning retry_needed if it fails
-spec run_txn(fun((ConfigKVList :: [[term()]],
                   UpdateFn :: fun((Key :: term(), Value :: term(), Cfg :: [term()]) -> NewConfig :: [[term()]]))
                  -> {commit, ConfigKVList :: [[term()]]} | {abort, any()})) ->
                     {commit, [term()]} | {abort, any()} | retry_needed.
run_txn(Body) ->
    run_txn_loop(Body, 10).

run_txn_loop(_Body, 0) ->
    retry_needed;
run_txn_loop(Body, RetriesLeft) ->
    Cfg = [get_kv_list()],
    case Body(Cfg, fun run_txn_set/3) of
        {commit, [NewCfg]} ->
            case cas_config(NewCfg, hd(Cfg)) of
                true -> {commit, NewCfg};
                false -> run_txn_loop(Body, RetriesLeft - 1)
            end;
        {abort, _} = AbortRV ->
            AbortRV
    end.

run_txn_set(Key, Value, [KVList]) ->
    [update_config_key(Key, Value, KVList)].

%% Updates Config with list of {Key, Value} pairs. Places new pairs at
%% the beginning of new list and removes old occurences of that keys.
%% Returns pair: {NewPairs, NewConfig}, where NewPairs is list of
%% updated KV pairs (with updated vclocks, if needed).
%%
%% Last parameter is accumulator. It's appended to NewPairs list.
set_kvlist([], Config, NewPairs) ->
    {NewPairs, Config};
set_kvlist([{Key, Value} | Rest], Config, NewPairs) ->
    NewList = update_config_key(Key, Value, Config),
    set_kvlist(Rest, NewList, [hd(NewList) | NewPairs]).

set(KVList) ->
    ok = update_with_changes(fun (Config) ->
                                     set_kvlist(KVList, Config, [])
                             end).

replace(KVList) -> gen_server:call(?MODULE, {replace, KVList}).

%% update config by applying Fun to it. Fun should return a pair
%% {NewPairs, NewConfig} where NewConfig is new config and NewPairs is
%% list of changed pairs. That list of changed pairs is announced via
%% ns_config_events.
update_with_changes(Fun) ->
    gen_server:call(?MODULE, {update_with_changes, Fun}).

%% updates config by applying Fun to every {Key, Value} pair. Fun
%% should return either new pair or Sentinel. In first case the pair
%% is replaced with it's new value. In later case the pair is removed
%% from config.
%%
%% Function returns a pair {NewPairs, NewConfig} where NewConfig is
%% new config and NewPairs is list of changed pairs
do_update_rec(_Fun, _Sentinel, [], NewConfig, NewPairs) ->
    {NewPairs, lists:reverse(NewConfig)};
do_update_rec(Fun, Sentinel, [Pair | Rest], NewConfig, NewPairs) ->
    StrippedPair = case Pair of
                       {K0, [_|_] = V0} -> {K0, strip_metadata(V0)};
                       _ -> Pair
                   end,
    case Fun(StrippedPair) of
        StrippedPair ->
            do_update_rec(Fun, Sentinel, Rest, [Pair | NewConfig], NewPairs);
        Sentinel ->
            do_update_rec(Fun, Sentinel, Rest, NewConfig, NewPairs);
        {K, Data} ->
            {_, OldValue} = Pair,
            NewPair = {K, increment_vclock(Data, OldValue)},
            do_update_rec(Fun, Sentinel, Rest, [NewPair | NewConfig], [NewPair | NewPairs])
    end.

update(Fun, Sentinel) ->
    update_with_changes(fun (Config) ->
                                do_update_rec(Fun, Sentinel, Config, [], [])
                        end).

%% Applies given Fun to value of given Key. The Key must exist.
-spec update_key(term(), fun((term()) -> term())) ->
                        ok | {error | exit | throw, any(), any()}.
update_key(Key, Fun) ->
    update_with_changes(fun (Config) ->
                                case update_key_inner(Config, Key, Fun) of
                                    false ->
                                        erlang:throw({config_key_not_found, Key});
                                    V ->
                                        V
                                end
                        end).

update_key(Key, Fun, Default) ->
    update_with_changes(fun (Config) ->
                                case update_key_inner(Config, Key, Fun) of
                                    false ->
                                        NewConfig = update_config_key(Key, Default, Config),
                                        {[hd(NewConfig)], NewConfig};
                                    V ->
                                        V
                                end
                        end).

update_key_inner(Config, Key, Fun) ->
    case lists:keyfind(Key, 1, Config) of
        false ->
            false;
        {_, OldValue} ->
            StrippedValue = strip_metadata(OldValue),
            case Fun(StrippedValue) of
                StrippedValue ->
                    {[], Config};
                NewValue ->
                    NewConfig = update_config_key(Key, NewValue, Config),
                    {[hd(NewConfig)], NewConfig}
            end
    end.


-spec update_sub_key(term(), term(), fun((term()) -> term())) ->
                            ok | {error | exit | throw, any(), any()}.
update_sub_key(Key, SubKey, Fun) ->
    update_key(Key, fun (PList) ->
                            RV = misc:key_update(SubKey, PList, Fun),
                            case RV of
                                false -> PList;
                                _ -> RV
                            end
                    end).

%% Set subkey to a certain value. If subkey already exists then its value is
%% replaced. Otherwise it is created.
set_sub(Key, SubKey, Value) ->
    Replace = fun (_) -> Value end,
    ok = update_key(Key,
                    fun (PList) ->
                            case misc:key_update(SubKey, PList, Replace) of
                                false ->
                                    [ {SubKey, Value} | PList ];
                                RV -> RV
                            end
                    end).

%% Set subkeys of certain key in config. If some of the subkeys do not exist
%% they are created.
set_sub(Key, SubKVList) ->
    ok = update_key(Key,
                    fun (PList) ->
                            set_sub_kvlist(PList, SubKVList)
                    end).

set_sub_kvlist(PList, []) ->
    PList;
set_sub_kvlist(PList, [ {SubKey, Value} | Rest ]) ->
    Replace = fun (_) -> Value end,
    NewPList =
        case misc:key_update(SubKey, PList, Replace) of
            false ->
                [ {SubKey, Value} | PList ];
            RV -> RV
        end,
    set_sub_kvlist(NewPList, Rest).


clear() -> clear([]).
clear(Keep) -> gen_server:call(?MODULE, {clear, Keep}).

% ----------------------------------------

% Returns an opaque Config object that's a snapshot of the configuration.
% The Config object can be passed to the search*() related set
% of functions.

get()              -> diag_handler:diagnosing_timeouts(
                        fun () ->
                                gen_server:call(?MODULE, get, ?DEFAULT_TIMEOUT)
                        end).
get(Node)          -> ?MODULE:get(Node, ?DEFAULT_TIMEOUT).
get(Node, Timeout) -> gen_server:call({?MODULE, Node}, get, Timeout).

-spec get_kv_list() -> [{term(), term()}].
get_kv_list() -> get_kv_list(?DEFAULT_TIMEOUT).

-spec get_kv_list(timeout()) -> [{term(), term()}].
get_kv_list(Timeout) -> config_dynamic(ns_config:get(node(), Timeout)).

% ----------------------------------------

search(Key) ->
    eval(
      fun (Config) ->
              search(Config, Key)
      end).

search_node(Key) -> search_node(?MODULE:get(), Key).

search('latest-config-marker', Key) ->
    search(Key);
search(Config, Key) ->
    case search_raw(Config, Key) of
        {value, X} -> {value, strip_metadata(X)};
        false      -> false
    end.

search(Config, Key, Default) ->
    case search(Config, Key) of
        {value, V} ->
            V;
        false ->
            Default
    end.

search_with_vclock_kvlist([], _Key) -> false;
search_with_vclock_kvlist([KVList | Rest], Key) ->
    case lists:keyfind(Key, 1, KVList) of
        {_, [{'_vclock', Clock} | Value]} ->
            {value, Value, Clock};
        {_, Value} ->
            {value, Value, undefined};
        false ->
            search_with_vclock_kvlist(Rest, Key)
    end.

get_static_and_dynamic({config, _Init, SL, DL, _PolicyMod}) -> [hd(DL) | SL];
get_static_and_dynamic(#config{dynamic = DL, static = SL}) -> [hd(DL) | SL].

search_with_vclock(Config, Key) ->
    LL = get_static_and_dynamic(Config),
    search_with_vclock_kvlist(LL, Key).

search_node(Config, Key) ->
    search_node(node(), Config, Key).

search_node(Node, Config, Key) ->
    case search(Config, {node, Node, Key}) of
        {value, '_use_global_value'} ->
            search(Config, Key);
        {value, _} = V ->
            V;
        false ->
            search(Config, Key)
    end.

% Returns the Value or undefined.

search_prop(Config, Key, SubKey) ->
    search_prop(Config, Key, SubKey, undefined).

search_node_prop(Config, Key, SubKey) ->
    search_node_prop(node(), Config, Key, SubKey, undefined).

% Returns the Value or the DefaultSubVal.

search_prop(Config, Key, SubKey, DefaultSubVal) ->
    case search(Config, Key) of
        {value, PropList} ->
            proplists:get_value(SubKey, PropList, DefaultSubVal);
        false ->
            DefaultSubVal
    end.

search_node_prop(Node, Config, Key, SubKey) when is_atom(Node) ->
    search_node_prop(Node, Config, Key, SubKey, undefined);
search_node_prop(Config, Key, SubKey, DefaultSubVal) ->
    search_node_prop(node(), Config, Key, SubKey, DefaultSubVal).

search_node_prop(Node, Config, Key, SubKey, DefaultSubVal) ->
    case search_node(Node, Config, Key) of
        {value, PropList} ->
            case proplists:get_value(SubKey, PropList, DefaultSubVal) of
                '_use_global_value' ->
                    search_prop(Config, Key, SubKey, DefaultSubVal);
                V ->
                    V
            end;
        false ->
            DefaultSubVal
    end.

% Returns the full KeyValTuple (eg, {Key, Val}) or undefined.

search_prop_tuple(Config, Key, SubKey) ->
    search_prop_tuple(Config, Key, SubKey, undefined).

% Returns the full KeyValTuple (eg, {Key, Val}) or the DefaultTuple.

search_prop_tuple(Config, Key, SubKey, DefaultTuple) ->
    case search(Config, Key) of
        {value, PropList} ->
            % We have our own proplist_get_value implementation because
            % the tuples in our config might not be clean {Key, Val}
            % 2-tuples, but might look like {Key, Val, More, Stuff},
            % and we want to return the full tuple.
            %
            % proplists:get_value(SubKey, PropList, DefaultSubVal);
            %
            proplist_get_value(SubKey, PropList, DefaultTuple);
        false ->
            DefaultTuple
    end.

% The search_raw API does not strip out metadata from results.

search_raw(undefined, _Key) -> false;
search_raw([], _Key)        -> false;
search_raw([KVList | Rest], Key) ->
    case lists:keysearch(Key, 1, KVList) of
        {value, {Key, V}} -> {value, V};
        _                 -> search_raw(Rest, Key)
    end;
search_raw({config, _Init, SL, DL, _PolicyMod}, Key) ->
    case search_raw(DL, Key) of
        {value, _} = R -> R;
        false          -> search_raw(SL, Key)
    end;
search_raw(#config{dynamic = DL, static = SL}, Key) ->
    case search_raw(DL, Key) of
        {value, _} = R -> R;
        false          -> search_raw(SL, Key)
    end.

upgrade_config_explicitly(Upgrader) ->
    gen_server:call(?MODULE, {upgrade_config_explicitly, Upgrader}).

config_version_token() ->
    {ets:lookup(ns_config_announces_counter, changes_counter), erlang:whereis(?MODULE)}.

fold(_Fun, Acc, undefined) ->
    Acc;
fold(_Fun, Acc, []) ->
    Acc;
fold(Fun, Acc0, [KVList | Rest]) ->
    Acc = lists:foldl(
            fun ({Key, Value}, Acc1) ->
                    Fun(Key, strip_metadata(Value), Acc1)
            end, Acc0, KVList),
    fold(Fun, Acc, Rest);
fold(Fun, Acc, {config, _Init, SL, DL, _PolicyMod}) ->
    fold(Fun, fold(Fun, Acc, DL), SL);
fold(Fun, Acc, #config{dynamic = DL, static = SL}) ->
    fold(Fun, fold(Fun, Acc, DL), SL);
fold(Fun, Acc, 'latest-config-marker') ->
    fold(Fun, Acc, ns_config:get()).

%% Implementation

proplist_get_value(_Key, [], DefaultTuple) -> DefaultTuple;
proplist_get_value(Key, [KeyValTuple | Rest], DefaultTuple) ->
    case element(1, KeyValTuple) =:= Key of
        true  -> KeyValTuple;
        false -> proplist_get_value(Key, Rest, DefaultTuple)
    end.

% Removes metadata like METADATA_VCLOCK from results.
strip_metadata([{'_vclock', _} | Rest]) ->
    Rest;
strip_metadata(Value) ->
    Value.

extract_vclock([{'_vclock', Clock} | _]) -> Clock;
extract_vclock(_Value) -> [].

%% Increment the vclock in V2 and replace the one in V1
increment_vclock(NewValue, OldValue) ->
    OldVClock = extract_vclock(OldValue),
    NewVClock = lists:sort(vclock:increment(node(), OldVClock)),
    [{?METADATA_VCLOCK, NewVClock} | strip_metadata(NewValue)].

%% Set the vclock in NewValue to one that descends from both
merge_vclocks(NewValue, OldValue) ->
    NewValueVClock = extract_vclock(NewValue),
    OldValueVClock = extract_vclock(OldValue),
    case NewValueVClock =:= [] andalso OldValueVClock =:= [] of
        true ->
            NewValue;
        _ ->
            NewVClock = lists:sort(vclock:merge([OldValueVClock, NewValueVClock])),
            [{?METADATA_VCLOCK, NewVClock} | strip_metadata(NewValue)]
    end.

attach_vclock(Value) ->
    VClock = lists:sort(vclock:increment(node(), vclock:fresh())),
    [{?METADATA_VCLOCK, VClock} | strip_metadata(Value)].

%% gen_server callbacks

upgrade_config(Config) ->
    Upgrader = fun (Cfg) ->
                       (Cfg#config.policy_mod):upgrade_config(Cfg)
               end,
    upgrade_config(Config, Upgrader).

upgrade_config(Config, Upgrader) ->
    do_upgrade_config(Config, Upgrader(Config), Upgrader).

do_upgrade_config(Config, [], _Upgrader) -> Config;
do_upgrade_config(Config, Changes, Upgrader) ->
    ?log_debug("Upgrading config by changes:~n~p~n", [ns_config_log:sanitize(Changes)]),
    ConfigList = config_dynamic(Config),
    NewList =
        lists:foldl(fun ({set, K,V}, Acc) ->
                            case lists:keyfind(K, 1, Acc) of
                                false ->
                                    [{K, attach_vclock(V)} | Acc];
                                {K, OldV} ->
                                    NewV =
                                        case is_list(OldV) of
                                            true ->
                                                case proplists:get_value(?METADATA_VCLOCK, OldV) of
                                                    undefined ->
                                                        %% we encountered plenty of upgrade
                                                        %% problems coming from the fact that
                                                        %% both old and new values miss vclock;
                                                        %% in this case the new value can be
                                                        %% reverted by the old value replicated
                                                        %% from not yet updated node;
                                                        %% we solve this by attaching vclock to
                                                        %% new value;
                                                        %% actually we're not supposed to update
                                                        %% not per-node values; but we still attach
                                                        %% vclock to them mostly for uniformity;
                                                        attach_vclock(V);
                                                    _ ->
                                                        increment_vclock(V, OldV)
                                                end;
                                            _ ->
                                                attach_vclock(V)
                                        end,
                                    lists:keyreplace(K, 1, Acc, {K, NewV})
                            end
                    end,
                    ConfigList,
                    Changes),
    NewConfig = Config#config{dynamic=[NewList]},
    do_upgrade_config(NewConfig, Upgrader(NewConfig), Upgrader).

do_init(Config) ->
    erlang:process_flag(trap_exit, true),
    %% NOTE: init may be called more than once via
    %% handle_call(reload,...) path
    (catch ets:new(ns_config_announces_counter, [set, named_table])),
    ets:insert_new(ns_config_announces_counter, {changes_counter, 0}),
    UpgradedConfig = upgrade_config(Config),
    InitialState =
        if
            UpgradedConfig =/= Config ->
                ?log_debug("Upgraded initial config:~n~p~n", [ns_config_log:sanitize(UpgradedConfig)]),
                initiate_save_config(UpgradedConfig);
            true ->
                UpgradedConfig
        end,
    {ok, InitialState}.

init({with_state, LoadedConfig} = Init) ->
    do_init(LoadedConfig#config{init = Init});
init({full, ConfigPath, DirPath, PolicyMod} = Init) ->
    erlang:process_flag(priority, high),
    case load_config(ConfigPath, DirPath, PolicyMod) of
        {ok, Config} ->
            do_init(Config#config{init = Init,
                                  saver_mfa = {?MODULE, save_config_sync, []}});
        Error ->
            {stop, Error}
    end;

init([ConfigPath, PolicyMod]) ->
    init({full, ConfigPath, undefined, PolicyMod}).

-spec wait_saver(#config{}, infinity | non_neg_integer()) -> {ok, #config{}} | timeout.
wait_saver(State, Timeout) ->
    case State#config.saver_pid of
        undefined ->
            ?log_debug("Waited for saver done. State=~n~p", [State]),
            {ok, State};
        Pid ->
            ?log_debug("Waiting for running saver"),
            receive
                {'EXIT', Pid, _Reason} = X ->
                    ?log_debug("Got exit from saver: ~p", [X]),
                    {noreply, NewState} = handle_info(X, State),
                    wait_saver(NewState, Timeout)
            after Timeout ->
                    timeout
            end
    end.

terminate(_Reason, State) ->
    case wait_saver(State, ?TERMINATE_SAVE_TIMEOUT) of
        timeout ->
            ?user_log(?GOT_TERMINATE_SAVE_TIMEOUT,
                      "Termination wait for ns_config saver process timed out.~n");
        _ -> ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_cast(stop, State) ->
    {stop, shutdown, State}.

handle_info({'EXIT', Pid, Reason},
            #config{saver_pid = MyPid,
                    pending_more_save = NeedMore} = State) when MyPid =:= Pid ->
    NewState = State#config{saver_pid = undefined},
    case Reason of
        normal ->
            ok;
        _ ->
            ?log_error("Saving ns_config failed. Trying to ignore: ~p", [Reason])
    end,
    S = case NeedMore of
            true ->
                initiate_save_config(NewState);
            false ->
                NewState
        end,
    {noreply, S};
handle_info(Info, State) ->
    ?log_warning("Unhandled message: ~p", [Info]),
    {noreply, State}.

handle_call({eval, Fun}, _From, State) ->
    {reply, catch Fun(State), State};

handle_call(reload, _From, State) ->
    case init(State#config.init) of
        {ok, State2}  -> {reply, ok, State2};
        {stop, Error} -> ?user_log(?RELOAD_FAILED, "reload failed: ~p",
                                   [Error]),
                         {reply, {error, Error}, State}
    end;

handle_call(resave, _From, State) ->
    {reply, ok, initiate_save_config(State)};

handle_call(reannounce, _From, State) ->
    %% we have to assume those are all genuine just made local changes
    announce_locally_made_changes(config_dynamic(State)),
    {reply, ok, State};

handle_call(get, _From, State) ->
    CompatibleState = {config, {}, State#config.static, State#config.dynamic, State#config.policy_mod},
    {reply, CompatibleState, State};

handle_call(get_raw, _From, State) -> {reply, State, State};

handle_call({replace, KVList}, _From, State) ->
    {reply, ok, State#config{dynamic = [KVList]}};

handle_call({update_with_changes, Fun}, From, State) ->
    OldList = config_dynamic(State),
    try Fun(OldList) of
        {[], _} ->
            {reply, ok, State};
        {NewPairs, NewConfig} ->
            announce_locally_made_changes(NewPairs),
            handle_call(resave, From, State#config{dynamic=[NewConfig]})
    catch
        T:E ->
            Stacktrace = erlang:get_stacktrace(),
            ?log_error("Failed to update config: ~p~nStacktrace: ~n~p",
                       [{T, E}, Stacktrace]),
            {reply, {T, E, Stacktrace}, State}
    end;

handle_call({clear, Keep}, From, State) ->
    NewList = lists:filter(fun({K,_V}) -> lists:member(K, Keep) end,
                           config_dynamic(State)),
    {reply, _, NewState} = handle_call(resave, From, State#config{dynamic=[NewList]}),
    %% we ignore state from saver, 'cause we're going to reload it anyway
    wait_saver(NewState, infinity),
    RV = handle_call(reload, From, State),
    ?log_debug("Full result of clear:~n~p", [RV]),
    RV;

handle_call({cas_config, NewKVList, OldKVList}, _From, State) ->
    case OldKVList =:= hd(State#config.dynamic) of
        true ->
            NewState = State#config{dynamic = [NewKVList]},
            announce_changes(NewKVList -- OldKVList),
            {reply, true, initiate_save_config(NewState)};
        _ ->
            {reply, false, State}
    end;

handle_call({upgrade_config_explicitly, Upgrader}, _From, State) ->
    {reply, ok, upgrade_config(State, Upgrader)}.


%%--------------------------------------------------------------------

% TODO: We're currently just taking the first dynamic KVList,
%       and should instead be smushing all the dynamic KVLists together?
config_dynamic(#config{dynamic = [X | _]}) -> X;
config_dynamic(#config{dynamic = []})      -> [];
config_dynamic({config, _Init, _Static, Dynamic, _PolicyMod}) ->
    case Dynamic of
        [] -> Dynamic;
        [X | _] -> X
    end.

%%--------------------------------------------------------------------

dynamic_config_path(DirPath) ->
    C = filename:join(DirPath, "config.dat"),
    ok = filelib:ensure_dir(C),
    C.

load_config(ConfigPath, DirPath, PolicyMod) ->
    DefaultConfig = PolicyMod:default(),
    % Static config file.
    ?log_info("Loading static config from ~p", [ConfigPath]),
    case load_file(txt, ConfigPath) of
        {ok, S} ->
            % Dynamic data directory.
            DirPath2 =
                case DirPath of
                    undefined ->
                        {value, DP} = search([S, DefaultConfig], directory),
                        DP;
                    _ -> DirPath
                end,
            % Dynamic config file.
            C = dynamic_config_path(DirPath2),
            ok = filelib:ensure_dir(C),
            ?log_info("Loading dynamic config from ~p", [C]),
            D = case load_file(bin, C) of
                    {ok, DRead} -> DRead;
                    not_found ->
                        ?log_info("No dynamic config file found. Assuming we're brand new node"),
                        []
                end,
            ?log_debug("Here's full dynamic config we loaded:~n~p", [ns_config_log:sanitize(D)]),
            {_, DynamicPropList} = lists:foldl(fun (Tuple, {Seen, Acc}) ->
                                                       K = element(1, Tuple),
                                                       case sets:is_element(K, Seen) of
                                                           true -> {Seen, Acc};
                                                           false -> {sets:add_element(K, Seen),
                                                                     [Tuple | Acc]}
                                                       end
                                               end,
                                               {sets:from_list([directory]), []},
                                               lists:append(D ++ [S, DefaultConfig])),
            ?log_info("Here's full dynamic config we loaded + static & default config:~n~p",
                      [ns_config_log:sanitize(DynamicPropList)]),
            {ok, #config{static = [S, DefaultConfig],
                         dynamic = [lists:keysort(1, DynamicPropList)],
                         policy_mod = PolicyMod}};
        E ->
            ?log_error("Failed loading static config: ~p", [E]),
            E
    end.

save_config_sync(#config{dynamic = D}, DirPath) ->
    C = dynamic_config_path(DirPath),
    ok = save_file(bin, C, D),
    ok.

save_config_sync(Config) ->
    {value, DirPath} = search(Config, directory),
    save_config_sync(Config, DirPath).

initiate_save_config(Config) ->
    case Config#config.saver_pid of
        undefined ->
            {M, F, ASuffix} = Config#config.saver_mfa,
            A = [Config | ASuffix],
            Pid = proc_lib:spawn_link(M, F, A),
            Config#config{saver_pid = Pid,
                          pending_more_save = false};
        _ ->
            Config#config{pending_more_save = true}
    end.

announce_locally_made_changes([]) ->
    ok;
announce_locally_made_changes(KVList) ->
    announce_changes(KVList),
    gen_event:notify(ns_config_events_local, [K || {K, _} <- KVList]).

announce_changes([]) -> ok;
announce_changes(KVList) ->
    ets:update_counter(ns_config_announces_counter, changes_counter, 1),
    % Fire a event per changed key.
    lists:foreach(fun ({Key, Value}) ->
                          gen_event:notify(ns_config_events,
                                           {Key, strip_metadata(Value)})
                  end,
                  KVList),
    % Fire a generic event that 'something changed'.
    gen_event:notify(ns_config_events, KVList).

load_file(txt, ConfigPath) -> read_includes(ConfigPath);

load_file(bin, ConfigPath) ->
    case file:read_file(ConfigPath) of
        {ok, <<>>} -> not_found;
        {ok, B}    -> {ok, binary_to_term(B)};
        _          -> not_found
    end.

save_file(bin, ConfigPath, X) ->
    TempFile = path_config:tempfile(filename:dirname(ConfigPath),
                                    filename:basename(ConfigPath),
                                    ".tmp"),
    {ok, F} = file:open(TempFile, [write, raw]),
    ok = file:write(F, term_to_binary(X)),
    ok = file:sync(F),
    ok = file:close(F),
    file:rename(TempFile, ConfigPath).

-spec merge_kv_pairs([{term(), term()}], [{term(), term()}]) -> [{term(), term()}].
merge_kv_pairs(RemoteKVList, LocalKVList) when RemoteKVList =:= LocalKVList -> LocalKVList;
merge_kv_pairs(RemoteKVList, LocalKVList) ->
    RemoteKVList1 = lists:sort(RemoteKVList),
    LocalKVList1 = lists:sort(LocalKVList),
    Merger = fun (_, {directory, _} = LP) ->
                     LP;
                 ({_, RV} = RP, {_, LV} = LP) ->
                     if
                         is_list(RV) orelse is_list(LV) ->
                             merge_list_values(RP, LP);
                         true ->
                             RP
                     end
             end,
    misc:ukeymergewith(Merger, 1, RemoteKVList1, LocalKVList1).

-spec merge_list_values({term(), term()}, {term(), term()}) -> {term(), term()}.
merge_list_values({_K, RV} = RP, {_, LV} = _LP) when RV =:= LV -> RP;
merge_list_values({K, RV} = RP, {_, LV} = LP) ->
    RClock = extract_vclock(RV),
    LClock = extract_vclock(LV),
    case {vclock:descends(RClock, LClock),
          vclock:descends(LClock, RClock)} of
        {X, X} ->
            case strip_metadata(RV) =:= strip_metadata(LV) of
                true ->
                    lists:max([LP, RP]);
                false ->
                    ChooseLeft = case RClock =:= LClock of
                                     true ->
                                         LV < RV;
                                     false ->
                                         vclock:likely_newer(LClock, RClock)
                                 end,
                    V = case ChooseLeft of
                            true ->
                                ?user_log(?CONFIG_CONFLICT,
                                          "Conflicting configuration changes to field "
                                          "~p:~n~p and~n~p, choosing the former, which looks newer.~n",
                                          [K,
                                           ns_config_log:sanitize(LV),
                                           ns_config_log:sanitize(RV)]),
                                LV;
                            false ->
                                ?user_log(?CONFIG_CONFLICT,
                                          "Conflicting configuration changes to field "
                                          "~p:~n~p and~n~p, choosing the former.~n",
                                          [K,
                                           ns_config_log:sanitize(RV),
                                           ns_config_log:sanitize(LV)]),
                                RV
                        end,
                    %% Increment the merged vclock so we don't pingpong
                    {K, increment_vclock(V, merge_vclocks(RV, LV))}
            end;
        {true, false} -> RP;
        {false, true} -> LP
    end.

read_includes(Path) -> read_includes([{include, Path}], []).

read_includes([{include, Path} | Terms], Acc) ->
  case file:consult(Path) of
    {ok, IncTerms}  -> read_includes(IncTerms ++ Terms, Acc);
    {error, enoent} -> {error, {bad_config_path, Path}};
    Error           -> Error
  end;
read_includes([X | Rest], Acc) -> read_includes(Rest, [X | Acc]);
read_includes([], Result)      -> {ok, lists:reverse(Result)}.

%% waits till all config change notifications are processed by
%% ns_config_events
sync_announcements() ->
    Pid = spawn(
            fun () ->
                    gen_event:sync_notify(ns_config_events,
                                          barrier)
            end),
    %% we don't need return value, but because this request will be
    %% queued we'll receive reply only after all currently queued
    %% messages to ns_config_events_local are consumed
    gen_event:which_handlers(ns_config_events_local),
    misc:wait_for_process(Pid, infinity),
    receive
        %% if our process is trapping exits we need to consume exit
        %% message. And do that 'linked process died badly' handling
        %% ourselves
        {'EXIT', Pid, Reason} ->
            normal = Reason,
            ok
    after 0 ->
            ok
    end.

-ifdef(EUNIT).

setup_path_config() ->
    ets:new(path_config_override, [public, named_table, {read_concurrency, true}]),
    [ets:insert(path_config_override, {K, "."}) || K <- [path_config_tmpdir, path_config_datadir,
                                                         path_config_bindir, path_config_libdir,
                                                         path_config_etcdir]].

teardown_path_config() ->
    ets:delete(path_config_override).

do_setup() ->
    mock_gen_server:start_link({local, ?MODULE}),
    setup_path_config(),
    ok.

shutdown_process(Name) ->
    OldWaitFlag = erlang:process_flag(trap_exit, true),
    try
        Pid = whereis(Name),
        exit(Pid, shutdown),
        receive
            {'EXIT', Pid, _} -> ok
        end
    catch Kind:What ->
            io:format("Ignoring ~p:~p while shutting down ~p~n", [Kind, What, Name])
    end,
    erlang:process_flag(trap_exit, OldWaitFlag).

do_teardown(_V) ->
    teardown_path_config(),
    shutdown_process(?MODULE),
    ok.

all_test_() ->
    [{spawn, {foreach, fun do_setup/0, fun do_teardown/1,
              [fun test_setup/0,
               {"test_set", fun test_set/0},
               {"test_cas_config", fun test_cas_config/0},
               {"test_update_config", fun test_update_config/0},
               {"test_set_kvlist", fun test_set_kvlist/0},
               {"test_update", fun test_update/0}]}},
     {spawn, {foreach, fun setup_with_saver/0, fun teardown_with_saver/1,
              [{"test_with_saver_stop", fun test_with_saver_stop/0},
               {"test_clear", fun test_clear/0},
               {"test_with_saver_set_and_stop", fun test_with_saver_set_and_stop/0},
               {"test_clear_with_concurrent_save", fun test_clear_with_concurrent_save/0}]}}].

test_setup() ->
    F = fun () -> ok end,
    mock_gen_server:stub_call(?MODULE,
                              update_with_changes,
                              fun ({update_with_changes, X}) ->
                                      X
                              end),
    ?assertEqual(F, gen_server:call(ns_config, {update_with_changes, F})).

-define(assertConfigEquals(A, B), ?assertEqual(lists:sort([{K, strip_metadata(V)} || {K,V} <- A]),
                                               lists:sort([{K, strip_metadata(V)} || {K,V} <- B]))).

test_set() ->
    Self = self(),
    mock_gen_server:stub_call(?MODULE,
                              update_with_changes,
                              fun (Msg) ->
                                      Self ! Msg, ok
                              end),
    ns_config:set(test, 1),
    Updater0 = (fun () -> receive {update_with_changes, F} -> F end end)(),

    ?assertConfigEquals([{test, 1}], element(2, Updater0([]))),
    {[{test, [{'_vclock', _} | 1]}], Val2} = Updater0([{foo, 2}]),
    ?assertConfigEquals([{test, 1}, {foo, 2}], Val2),

    %% and here we're changing value, so expecting vclock
    {[{test, [{'_vclock', [_]} | 1]}], Val3} =
        Updater0([{foo, [{k, 1}, {v, 2}]},
                  {xar, true},
                  {test, [{a, b}, {c, d}]}]),

    ?assertConfigEquals([{foo, [{k, 1}, {v, 2}]},
                         {xar, true},
                         {test, 1}], Val3),

    SetVal1 = [{suba, true}, {subb, false}],
    ns_config:set(test, SetVal1),
    Updater1 = (fun () -> receive {update_with_changes, F} -> F end end)(),

    {[{test, SetVal1Actual1}], Val4} = Updater1([{test, [{suba, false}, {subb, true}]}]),
    MyNode = node(),
    ?assertMatch([{'_vclock', [{MyNode, _}]} | SetVal1], SetVal1Actual1),
    ?assertEqual(SetVal1, strip_metadata(SetVal1Actual1)),
    ?assertMatch([{test, SetVal1Actual1}], Val4).

test_cas_config() ->
    Self = self(),
    {ok, _FakeConfigEvents} = gen_event:start_link({local, ns_config_events}),
    try
        do_test_cas_config(Self)
    after
        (catch shutdown_process(ns_config_events)),
        (catch erlang:unregister(ns_config_events))
    end.

do_test_cas_config(Self) ->
    mock_gen_server:stub_call(?MODULE,
                              cas_config,
                              fun (Msg) ->
                                      Self ! Msg, ok
                              end),

    ets:new(ns_config_announces_counter, [set, named_table]),
    ets:insert_new(ns_config_announces_counter, {changes_counter, 0}),

    ns_config:cas_config(new, old),
    receive
        {cas_config, new, old} ->
            ok
    after 0 ->
            exit(missing_cas_config_msg)
    end,

    Config = #config{dynamic=[[{a,1},{b,1}]],
                     saver_mfa = {?MODULE, send_config, [Self]},
                     saver_pid = Self,
                     pending_more_save = true},
    ?assertEqual([{a,1},{b,1}], config_dynamic(Config)),


    {reply, true, NewConfig} = handle_call({cas_config, [{a,2}], config_dynamic(Config)}, [], Config),
    ?assertEqual(NewConfig, Config#config{dynamic=[config_dynamic(NewConfig)]}),
    ?assertEqual([{a,2}], config_dynamic(NewConfig)),

    {reply, false, NewConfig} = handle_call({cas_config, [{a,3}], config_dynamic(Config)}, [], NewConfig).


test_update_config() ->
    ?assertConfigEquals([{test, 1}], update_config_key(test, 1, [])),
    ?assertConfigEquals([{test, 1},
                         {foo, [{k, 1}, {v, 2}]},
                         {xar, true}],
                        update_config_key(test, 1, [{foo, [{k, 1}, {v, 2}]},
                                                    {xar, true},
                                                    {test, [{a, b}, {c, d}]}])).

test_set_kvlist() ->
    {NewPairs, [{foo, FooVal},
                {bar, [{'_vclock', _} | false]},
                {baz, [{nothing, false}]}]} =
        set_kvlist([{bar, false},
                    {foo, [{suba, a}, {subb, b}]}],
                   [{baz, [{nothing, false}]},
                    {foo, [{suba, undefined}, {subb, unlimited}]}], []),
    ?assertConfigEquals(NewPairs, [{foo, FooVal}, {bar, false}]),
    MyNode = node(),
    ?assertMatch([{'_vclock', [{MyNode, _}]}, {suba, a}, {subb, b}],
                 FooVal).

test_update() ->
    Self = self(),
    mock_gen_server:stub_call(?MODULE,
                              update_with_changes,
                              fun (Msg) ->
                                      Self ! Msg, ok
                              end),
    RecvUpdater = fun () ->
                          receive
                              {update_with_changes, F} -> F
                          end
                  end,

    OldConfig = [{dont_change, 1},
                 {erase, 2},
                 {list_value, [{'_vclock', [{'n@never-really-possible-hostname', {1, 12345}}]},
                               {a, b}, {c, d}]},
                 {a, 3},
                 {b, 4}],
    BlackSpot = make_ref(),
    ns_config:update(fun ({dont_change, _} = P) -> P;
                         ({erase, _}) -> BlackSpot;
                         ({list_value, V}) -> {list_value, [V | V]};
                         ({K, V}) -> {K, -V}
                     end, BlackSpot),
    Updater = RecvUpdater(),
    {Changes, NewConfig} = Updater(OldConfig),

    ?assertConfigEquals(Changes ++ [{dont_change, 1}],
                        NewConfig),
    ?assertEqual(lists:keyfind(dont_change, 1, Changes), false),

    ?assertEqual(lists:sort([dont_change, list_value, a, b]), lists:sort(proplists:get_keys(NewConfig))),

    {list_value, [{'_vclock', Clocks} | ListValues]} = lists:keyfind(list_value, 1, NewConfig),

    ?assertEqual({'n@never-really-possible-hostname', {1, 12345}},
                 lists:keyfind('n@never-really-possible-hostname', 1, Clocks)),
    MyNode = node(),
    ?assertMatch([{MyNode, _}], lists:keydelete('n@never-really-possible-hostname', 1, Clocks)),

    ?assertEqual([[{a, b}, {c, d}], {a, b}, {c, d}], ListValues),

    ?assertEqual(-3, strip_metadata(proplists:get_value(a, NewConfig))),
    ?assertEqual(-4, strip_metadata(proplists:get_value(b, NewConfig))),

    ?assertMatch([{N, _}] when N =:= node(), extract_vclock(proplists:get_value(a, NewConfig))),
    ?assertMatch([{N, _}] when N =:= node(), extract_vclock(proplists:get_value(b, NewConfig))),

    ns_config:update_key(a, fun (3) -> 10 end),
    Updater2 = RecvUpdater(),
    {[{a, [{'_vclock', [_]} | 10]}], NewConfig2} = Updater2(OldConfig),

    ?assertConfigEquals([{a, 10} | lists:keydelete(a, 1, OldConfig)], NewConfig2),
    ok.

send_config(Config, Pid) ->
    Ref = erlang:make_ref(),
    Pid ! {saving, Ref, Config, self()},
    receive
        {Ref, Reply} ->
            Reply
    end.

setup_with_saver() ->
    {ok, _} = gen_event:start_link({local, ns_config_events}),
    {ok, _} = gen_event:start_link({local, ns_config_events_local}),
    Parent = self(),
    setup_path_config(),
    %% we don't want to kill this process when ns_config server dies,
    %% but we wan't to kill ns_config process when this process dies
    proc_lib:start(
      erlang, apply,
      [fun () ->
               Cfg = #config{dynamic = [[{config_version, ns_config_default:get_current_version()},
                                         {a, [{b, 1}, {c, 2}]},
                                         {d, 3}]],
                             policy_mod = ns_config_default,
                             saver_mfa = {?MODULE, send_config, [save_config_target]}},
               {ok, _} = ns_config:start_link({with_state, Cfg}),
               MRef = erlang:monitor(process, Parent),

               proc_lib:init_ack(self()),

               receive
                   {'DOWN', MRef, _, _, _} ->
                       ?debugFmt("Commiting suicide~n", []),
                       exit(death)
               end
       end, []]).

kill_and_wait(undefined) -> ok;
kill_and_wait(Pid) ->
    (catch erlang:unlink(Pid)),
    exit(Pid, kill),
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, _, _, _} -> ok
    end.

teardown_with_saver(_) ->
    teardown_path_config(),
    kill_and_wait(whereis(ns_config)),
    kill_and_wait(whereis(ns_config_events)),
    kill_and_wait(whereis(ns_config_events_local)),
    ok.

fail_on_incoming_message() ->
    receive
        X ->
            exit({i_dont_expect_anything, X})
    after
        0 -> ok
    end.

test_with_saver_stop() ->
    do_test_with_saver(fun (_Pid) ->
                               gen_server:cast(?MODULE, stop)
                       end,
                       fun () ->
                               ok
                       end).

test_with_saver_set_and_stop() ->
    do_test_with_saver(fun (_Pid) ->
                               %% check that pending_more_save is false
                               Cfg1 = gen_server:call(ns_config, get_raw),
                               ?assertEqual(false, Cfg1#config.pending_more_save),

                               %% send last mutation
                               ns_config:set(d, 10),

                               %% check that pending_more_save is false
                               Cfg2 = gen_server:call(ns_config, get_raw),
                               ?assertEqual(true, Cfg2#config.pending_more_save),

                               %% and kill ns_config
                               gen_server:cast(?MODULE, stop)
                       end,
                       fun () ->
                               %% wait for last save request and confirm it
                               receive
                                   {saving, Ref, _Conf, Pid} ->
                                       Pid ! {Ref, ok};
                                   X ->
                                       exit({unexpected_message, X})
                               end,
                               ok
                       end).

do_test_with_saver(KillerFn, PostKillerFn) ->
    erlang:process_flag(trap_exit, true),
    true = erlang:register(save_config_target, self()),

    ?assertEqual({value, 3}, ns_config:search(d)),
    ?assertEqual(2, ns_config:search_prop(ns_config:get(), a, c)),

    ns_config:set(d, 4),

    {NewConfig1, Ref1, Pid1} = receive
                                   {saving, R, C, P} -> {C, R, P}
                               end,

    fail_on_incoming_message(),

    ?assertEqual({value, 4}, ns_config:search(NewConfig1, d)),

    ns_config:set(d, 5),

    %% ensure that save request is not sent while first is not yet
    %% complete
    fail_on_incoming_message(),

    %% and actually check that pending_more_save is true
    Cfg1 = gen_server:call(ns_config, get_raw),
    ?assertEqual(true, Cfg1#config.pending_more_save),

    %% now signal save completed
    Pid1 ! {Ref1, ok},

    %% expect second save request immediately
    {_, Ref2, Pid2} = receive
                          {saving, R1, C1, P1} -> {C1, R1, P1}
                      end,

    Cfg2 = gen_server:call(ns_config, get_raw),
    ?assertEqual(false, Cfg2#config.pending_more_save),

    Pid = whereis(ns_config),
    erlang:monitor(process, Pid),

    %% send termination request, but before completing second save
    %% request
    KillerFn(Pid),

    fail_on_incoming_message(),

    %% now confirm second save
    Pid2 ! {Ref2, ok},

    PostKillerFn(),

    %% await ns_config death
    receive
        {'DOWN', _MRef, process, Pid, Reason} ->
            ?assertEqual(shutdown, Reason)
    end,

    %% make sure there are no unhandled messages
    fail_on_incoming_message(),

    ok.

test_clear() ->
    erlang:process_flag(trap_exit, true),
    true = erlang:register(save_config_target, self()),

    ?assertEqual({value, 3}, ns_config:search(d)),
    ?assertEqual(2, ns_config:search_prop(ns_config:get(), a, c)),

    ns_config:set(d, 4),

    NewConfig1 = receive
                     {saving, Ref1, C, Pid1} ->
                         Pid1 ! {Ref1, ok},
                         C
                 end,

    fail_on_incoming_message(),

    ?assertEqual({value, 4}, ns_config:search(NewConfig1, d)),

    %% ns_config:clear blocks on saver, so we need concurrency here
    Clearer = spawn_link(fun () ->
                                 ns_config:clear([])
                         end),

    %% make sure we're saving correctly cleared config
    receive
        {saving, Ref2, NewConfig2, Pid2} ->
            Pid2 ! {Ref2, ok},
            ?assertEqual([], config_dynamic(NewConfig2))
    end,

    receive
        {'EXIT', Clearer, normal} -> ok
    end,

    fail_on_incoming_message(),

    %% now verify that ns_config was re-inited. In our case this means
    %% returning to original config
    ?assertEqual({value, 3}, ns_config:search(d)),
    ?assertEqual(2, ns_config:search_prop(ns_config:get(), a, c)).

test_clear_with_concurrent_save() ->
    erlang:process_flag(trap_exit, true),
    true = erlang:register(save_config_target, self()),

    ?assertEqual({value, 3}, ns_config:search(d)),
    ?assertEqual(2, ns_config:search_prop(ns_config:get(), a, c)),

    ns_config:set(d, 4),

    %% don't reply right now
    {NewConfig1, Pid1, Ref1} = receive
                                   {saving, R1, C, P1} ->
                                       {C, P1, R1}
                               end,

    fail_on_incoming_message(),

    ?assertEqual({value, 4}, ns_config:search(NewConfig1, d)),

    %% ns_config:clear blocks on saver, so we need concurrency here
    Clearer = spawn_link(fun () ->
                                 ns_config:clear([])
                         end),

    %% this is racy, but don't know how to test other process waiting
    %% on reply from us
    timer:sleep(300),

    %% now assuming ns_config is waiting on us already, reply on first
    %% save request
    fail_on_incoming_message(),
    Pid1 ! {Ref1, ok},

    %% make sure we're saving correctly cleared config
    receive
        {saving, Ref2, NewConfig2, Pid2} ->
            Pid2 ! {Ref2, ok},
            ?assertEqual([], config_dynamic(NewConfig2))
    end,

    receive
        {'EXIT', Clearer, normal} -> ok
    end,

    fail_on_incoming_message(),

    %% now verify that ns_config was re-inited. In our case this means
    %% returning to original config
    ?assertEqual({value, 3}, ns_config:search(d)),
    ?assertEqual(2, ns_config:search_prop(ns_config:get(), a, c)).

upgrade_config_case(InitialList, Changes, ExpectedList) ->
    Upgrader = fun (_) -> [] end,
    upgrade_config_case(InitialList, Changes, ExpectedList, Upgrader).

upgrade_config_case(InitialList, Changes, ExpectedList, Upgrader) ->
    Config = #config{dynamic=[InitialList]},
    UpgradedConfig = do_upgrade_config(Config,
                                       Changes,
                                       Upgrader),
    StrippedUpgradedConfig = lists:map(fun ({K, V}) ->
                                               {K, strip_metadata(V)}
                                       end, config_dynamic(UpgradedConfig)),
    ?assertEqual(lists:sort(ExpectedList),
                 lists:sort(StrippedUpgradedConfig)).

upgrade_config_testgen(InitialList, Changes, ExpectedList) ->
    Title = iolist_to_binary(io_lib:format("~p + ~p = ~p~n", [InitialList, Changes, ExpectedList])),
    {Title,
     fun () -> upgrade_config_case(InitialList, Changes, ExpectedList) end}.

upgrade_config_test_() ->
    T = [{[{a, 1}, {b, 2}], [{set, a, 2}, {set, c, 3}], [{a, 2}, {b, 2}, {c, 3}]},
         {[{b, 2}, {a, 1}], [{set, a, 2}, {set, c, 3}], [{a, 2}, {b, 2}, {c, 3}]},
         {[{b, 2}, {a, [{moxi, "asd"}, {memcached, "ffd"}]}, {c, 0}],
          [{set, a, [{moxi, "new"}, {memcached, "newff"}]}, {set, c, 3}],
          [{a, [{moxi, "new"}, {memcached, "newff"}]}, {b, 2}, {c, 3}]}
        ],
    [upgrade_config_testgen(I, C, E) || {I,C,E} <- T].

upgrade_config_vclocks_test() ->
    Config = #config{dynamic=[[{{node, node(), a}, 1},
                               {unchanged, 2},
                               {b, 2},
                               {{node, node(), c}, attach_vclock(1)}]]},
    Changes = [{set, {node, node(), a}, 2},
               {set, b, 4},
               {set, {node, node(), c}, [3]},
               {set, d, [4]}],
    Upgrader = fun (_) -> [] end,
    UpgradedConfig = do_upgrade_config(Config, Changes, Upgrader),

    Get = fun (Config1, K) ->
                  {value, Value} = search_raw(Config1, K),
                  Value
          end,

    ?assertMatch([{Node, {_, _}}] when Node =:= node(),
                 extract_vclock(Get(UpgradedConfig, {node, node(), a}))),
    ?assertMatch([],
                 extract_vclock(Get(UpgradedConfig, unchanged))),
    ?assertMatch([{Node, {_, _}}] when Node =:= node(),
                 extract_vclock(Get(UpgradedConfig, b))),
    ?assertMatch([{Node, {_, _}}] when Node =:= node(),
                 extract_vclock(Get(UpgradedConfig, {node, node(), c}))),
    ?assertMatch([{Node, {_, _}}] when Node =:= node(),
                 extract_vclock(Get(UpgradedConfig, d))).

upgrade_config_with_many_upgrades_test_() ->
    {spawn, ?_test(test_upgrade_config_with_many_upgrades())}.

test_upgrade_config_with_many_upgrades() ->
    Initial = [{a, 1}],
    Ref = make_ref(),
    self() ! {Ref, [{set, a, 2}]},
    self() ! {Ref, [{set, a, 3}]},
    self() ! {Ref, []},
    Upgrader = fun (_) ->
                       receive
                           {Ref, X} -> X
                       end
               end,
    upgrade_config_case(Initial, Upgrader(any), [{a, 3}], Upgrader),
    receive
        X ->
            erlang:error({unexpected_message, X})
    after 0 ->
            ok
    end.

-endif.
