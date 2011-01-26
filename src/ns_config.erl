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

-define(DEFAULT_TIMEOUT, 500).
-define(TERMINATE_SAVE_TIMEOUT, 10000).

%% log codes
-define(RELOAD_FAILED, 1).
-define(RESAVE_FAILED, 2).
-define(CONFIG_CONFLICT, 3).
-define(GOT_TERMINATE_SAVE_TIMEOUT, 4).

-export([eval/1,
         start_link/2, start_link/1,
         get_remote/1, get_remote/2,
         merge/1,
         merge_remote/2, merge_remote/3,
         get/2, get/1, get/0, set/2, set/1,
         set_initial/2, update/2, update_key/2,
         update_sub_key/3,
         search_node/3, search_node/2, search_node/1,
         search_node_prop/3, search_node_prop/4,
         search_node_prop/5,
         search/2, search/1,
         search_prop/3, search_prop/4,
         search_prop_tuple/3, search_prop_tuple/4,
         search_raw/2,
         clear/0, clear/1,
         proplist_get_value/3,
         sync_announcements/0, get_diag/0]).

-export([save_config_sync/1]).

% Exported for tests only
-export([merge_configs/3, save_file/3, load_config/3,
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

-export([stop/0, reload/0, resave/0, reannounce/0, replace/1]).

%% API

eval(Fun) ->
    gen_server:call(?MODULE, {eval, Fun}).

start_link(Full) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Full, []).

start_link(ConfigPath, PolicyMod) -> start_link([ConfigPath, PolicyMod]).

stop()       -> gen_server:cast(?MODULE, stop).
reload()     -> gen_server:call(?MODULE, reload).
resave()     -> gen_server:call(?MODULE, resave).
reannounce() -> gen_server:call(?MODULE, reannounce).

% ----------------------------------------

% Set & get configuration KVList, or [{Key, Val}*].
%
% The get_remote() only returns dyanmic tuples as its KVList result.

merge_remote(Node, KVList) ->
    merge_remote(Node, KVList, ?DEFAULT_TIMEOUT).
merge_remote(Node, KVList, Timeout) ->
    gen_server:call({?MODULE, Node}, {merge, KVList}, Timeout).

get_remote(Node, Timeout) -> config_dynamic(?MODULE:get(Node, Timeout)).
get_remote(Node) -> get_remote(Node, ?DEFAULT_TIMEOUT).

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
        [{Key, OldValue} | XX] ->
            NewPair = {Key, increment_vclock(Value, OldValue)},
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
        none -> [{Key, Value} | KVList];
        NewList -> NewList
    end.

set(Key, Value) ->
    ok = update_with_changes(fun (Config) ->
                                     NewList = update_config_key(Key, Value, Config),
                                     {[hd(NewList)], NewList}
                             end).

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
    {NewPairs, NewConfig};
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
update_key(Key, Fun) ->
    update_with_changes(fun (Config) ->
                                case lists:keyfind(Key, 1, Config) of
                                    {_, OldValue} ->
                                        StrippedValue = strip_metadata(OldValue),
                                        case Fun(StrippedValue) of
                                            StrippedValue ->
                                                {[], Config};
                                            NewValue ->
                                                NewConfig = update_config_key(Key, NewValue, Config),
                                                {[hd(NewConfig)], NewConfig}
                                        end
                                end
                        end).

update_sub_key(Key, SubKey, Fun) ->
    update_key(Key, fun (PList) ->
                            RV = misc:key_update(SubKey, PList, Fun),
                            case RV of
                                false -> PList;
                                _ -> RV
                            end
                    end).

clear() -> clear([]).
clear(Keep) -> gen_server:call(?MODULE, {clear, Keep}).

% ----------------------------------------

% Returns an opaque Config object that's a snapshot of the configuration.
% The Config object can be passed to the search*() related set
% of functions.

get()              -> diag_handler:diagnosing_timeouts(
                        fun () ->
                                gen_server:call(?MODULE, get)
                        end).
get(Node)          -> ?MODULE:get(Node, ?DEFAULT_TIMEOUT).
get(Node, Timeout) -> gen_server:call({?MODULE, Node}, get, Timeout).

get_diag() -> config_dynamic(ns_config:get()).

% ----------------------------------------

search(Key) -> search(?MODULE:get(), Key).

search_node(Key) -> search_node(?MODULE:get(), Key).

search(Config, Key) ->
    case search_raw(Config, Key) of
        {value, X} -> {value, strip_metadata(X)};
        false      -> false
    end.

search_node(Config, Key) ->
    search_node(node(), Config, Key).

search_node(Node, Config, Key) ->
    case search(Config, {node, Node, Key}) of
        {value, _} = V -> V;
        false          -> search(Config, Key)
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
            proplists:get_value(SubKey, PropList, DefaultSubVal);
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
search_raw(#config{dynamic = DL, static = SL}, Key) ->
    case search_raw(DL, Key) of
        {value, _} = R -> R;
        false          -> search_raw(SL, Key)
    end.

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

%% strip_metadata(Value) when is_list(Value) ->
%%     [X || X <- Value, not (is_tuple(X) andalso
%%                            lists:member(element(1, X), [?METADATA_VCLOCK,
%%                                                         '_ver']))];
%% strip_metadata(Value) ->
%%     Value.



%% Increment the vclock in V2 and replace the one in V1
increment_vclock(NewValue, OldValue) ->
    case is_list(NewValue) of
        true ->
            OldVClock =
                case is_list(OldValue) of
                    true ->
                        proplists:get_value(?METADATA_VCLOCK, OldValue, []);
                    false ->
                        []
                end,
            NewVClock = lists:sort(vclock:increment(node(), OldVClock)),
            [{?METADATA_VCLOCK, NewVClock} | lists:keydelete(?METADATA_VCLOCK, 1,
                                                             NewValue)];
        false ->
            NewValue
    end.

%% Set the vclock in NewValue to one that descends from both
merge_vclocks(NewValue, OldValue) ->
    NewValueVClock = proplists:get_value(?METADATA_VCLOCK, NewValue, []),
    OldValueVClock = proplists:get_value(?METADATA_VCLOCK, OldValue, []),
    NewVClock = lists:sort(vclock:merge([OldValueVClock, NewValueVClock])),
    [{?METADATA_VCLOCK, NewVClock} | lists:keydelete(?METADATA_VCLOCK,
                                                     1, NewValue)].

%% gen_server callbacks

do_init(Config) ->
    erlang:process_flag(trap_exit, true),
    {ok, Config}.

init({with_state, LoadedConfig} = Init) ->
    do_init(LoadedConfig#config{init = Init});
init({full, ConfigPath, DirPath, PolicyMod} = Init) ->
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
        undefined -> {ok, State};
        Pid ->
            receive
                {'EXIT', Pid, _Reason} = X ->
                    {noreply, NewState} = handle_info(X, State),
                    wait_saver(NewState, Timeout)
            after Timeout ->
                    timeout
            end
    end.

terminate(_Reason, State) ->
    case wait_saver(State, ?TERMINATE_SAVE_TIMEOUT) of
        timeout ->
            ns_log:log(?MODULE, ?GOT_TERMINATE_SAVE_TIMEOUT,
                       "Termination wait for ns_config saver process timed out.~n");
        _ -> ok
    end.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_cast(stop, State) ->
    {stop, shutdown, State}.

handle_info({'EXIT', Pid, _},
            #config{saver_pid = MyPid,
                    pending_more_save = NeedMore} = State) when MyPid =:= Pid ->
    NewState = State#config{saver_pid = undefined},
    S = case NeedMore of
            true ->
                initiate_save_config(NewState);
            false ->
                NewState
        end,
    {noreply, S};
handle_info(_Info, State) ->
    {noreply, State}.

handle_call({eval, Fun}, _From, State) ->
    {reply, catch Fun(State), State};

handle_call(reload, _From, State) ->
    case init(State#config.init) of
        {ok, State2}  -> {reply, ok, State2};
        {stop, Error} -> ns_log:log(?MODULE, ?RELOAD_FAILED, "reload failed: ~p",
                                    [Error]),
                         {reply, {error, Error}, State}
    end;

handle_call(resave, _From, State) ->
    {reply, ok, initiate_save_config(State)};

handle_call(reannounce, _From, State) ->
    announce_changes(config_dynamic(State)),
    {reply, ok, State};

handle_call(get, _From, State) -> {reply, State, State};

handle_call({replace, KVList}, _From, State) ->
    {reply, ok, State#config{dynamic = [KVList]}};

handle_call({update_with_changes, Fun}, From, State) ->
    OldList = config_dynamic(State),
    try Fun(OldList) of
        {NewPairs, NewConfig} ->
            announce_changes(NewPairs),
            handle_call(resave, From, State#config{dynamic=[NewConfig]})
    catch
        X:Error ->
            {reply, {X, Error, erlang:get_stacktrace()}, State}
    end;

handle_call({clear, Keep}, From, State) ->
    NewList = lists:filter(fun({K,_V}) -> lists:member(K, Keep) end,
                           config_dynamic(State)),
    {reply, _, NewState} = handle_call(resave, From, State#config{dynamic=[NewList]}),
    %% we ignore state from saver, 'cause we're going to reload it anyway
    wait_saver(NewState, infinity),
    handle_call(reload, From, State);

handle_call({merge, KVList}, From, State) ->
    PolicyMod = State#config.policy_mod,
    State2 = merge_configs(PolicyMod:mergable([State#config.dynamic,
                                               State#config.static,
                                               [KVList]]),
                           #config{dynamic = [KVList]},
                           State),
    case State2 =/= State of
        true ->
            case handle_call(resave, From, State2) of
                {reply, ok, State3} = Result ->
                    DynOld = lists:map(fun strip_metadata/1, config_dynamic(State)),
                    DynNew = lists:map(fun strip_metadata/1, config_dynamic(State3)),
                    DynChg = DynNew -- DynOld,
                    announce_changes(DynChg),
                    Result;
                Error ->
                    Error
            end;
        false -> {reply, ok, State2}
    end.

%%--------------------------------------------------------------------

% TODO: We're currently just taking the first dynamic KVList,
%       and should instead be smushing all the dynamic KVLists together?
config_dynamic(#config{dynamic = [X | _]}) -> X;
config_dynamic(#config{dynamic = []})      -> [];
config_dynamic(X)                          -> X.

%%--------------------------------------------------------------------

dynamic_config_path(DirPath) ->
    % The extra node() in the path ensures uniqueness even if
    % developers are running more than 1 named node per box.
    X = filename:join(DirPath, misc:node_name_short()),
    C = filename:join(X, "config.dat"),
    ok = filelib:ensure_dir(C),
    C.

load_config(ConfigPath, DirPath, PolicyMod) ->
    DefaultConfig = PolicyMod:default(),
    % Static config file.
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
            D = case load_file(bin, C) of
                    {ok, DRead} -> DRead;
                    _           -> []
                end,
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
            {ok, #config{static = [S, DefaultConfig],
                         dynamic = [lists:keysort(1, DynamicPropList)],
                         policy_mod = PolicyMod}};
        E -> E
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
            Pid = spawn_link(M, F, A),
            Config#config{saver_pid = Pid,
                          pending_more_save = false};
        _ ->
            Config#config{pending_more_save = true}
    end.

announce_changes([]) -> ok;
announce_changes(KVList) ->
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
    {ok, F} = file:open(ConfigPath, [write, raw]),
    ok = file:write(F, term_to_binary(X)),
    ok = file:close(F).

merge_configs(Mergable, Remote, Local) ->
    merge_configs(Mergable, Remote, Local, []).

merge_configs([], _Remote, Local, []) ->
    Local#config{dynamic = []};
merge_configs([], _Remote, Local, Acc) ->
    Local#config{dynamic = [lists:reverse(Acc)]};
merge_configs([directory = Field | Fields], Remote, Local, Acc) ->
    NewAcc = case search_raw(Local, Fields) of
                 {value, LV} -> [{Field, LV} | Acc];
                 _ -> Acc
             end,
    merge_configs(Fields, Remote, Local, NewAcc);
merge_configs([Field | Fields], Remote, Local, Acc) ->
    RS = search_raw(Remote, Field),
    LS = search_raw(Local, Field),
    A2 = case {RS, LS} of
             {{value, RV}, {value, LV}} when is_list(RV), is_list(LV) ->
                 merge_lists(Field, Acc, RV, LV);
             {{value, RV}, _} -> [{Field, RV} | Acc];
             {_, {value, LV}} -> [{Field, LV} | Acc];
             _                -> Acc
         end,
    merge_configs(Fields, Remote, Local, A2).

merge_lists(Field, Acc, RV, LV) ->
    RClock = proplists:get_value(?METADATA_VCLOCK, RV, []),
    LClock = proplists:get_value(?METADATA_VCLOCK, LV, []),
    case {vclock:descends(RClock, LClock),
          vclock:descends(LClock, RClock)} of
        {X, X} ->
            NewValue =
                case strip_metadata(RV) =:= strip_metadata(LV) of
                    true ->
                        RV;
                    false ->
                        case vclock:likely_newer(LClock, RClock) of
                            true ->
                                ns_log:log(?MODULE, ?CONFIG_CONFLICT,
                                           "Conflicting configuration changes to field "
                                           "~p:~n~p and~n~p, choosing the former, which looks newer.~n",
                                           [Field, LV, RV]),
                                %% Increment the merged vclock so we don't pingpong
                                increment_vclock(LV, merge_vclocks(LV, RV));
                            false ->
                                ns_log:log(?MODULE, ?CONFIG_CONFLICT,
                                           "Conflicting configuration changes to field "
                                           "~p:~n~p and~n~p, choosing the former.~n",
                                           [Field, RV, LV]),
                                %% Increment the merged vclock so we don't pingpong
                                increment_vclock(RV, merge_vclocks(RV, LV))
                        end
                end,
            [{Field, NewValue} | Acc];
        {true, false} -> [{Field, RV} | Acc];
        {false, true} -> [{Field, LV} | Acc]
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
    gen_event:sync_notify(ns_config_events,
                          barrier).

-ifdef(EUNIT).

do_setup() ->
    mock_gen_server:start_link({local, ?MODULE}),
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
    shutdown_process(?MODULE),
    ok.

all_test_() ->
    [{spawn, {foreach, fun do_setup/0, fun do_teardown/1,
              [fun test_setup/0,
               fun test_set/0,
               fun test_update_config/0,
               fun test_set_kvlist/0,
               fun test_update/0]}},
     {spawn, {foreach, fun setup_with_saver/0, fun teardown_with_saver/1,
              [fun test_with_saver_stop/0,
               fun test_clear/0,
               fun test_with_saver_set_and_stop/0,
               fun test_clear_with_concurrent_save/0]}}].

test_setup() ->
    F = fun () -> ok end,
    mock_gen_server:stub_call(?MODULE,
                              update_with_changes,
                              fun ({update_with_changes, X}) ->
                                      X
                              end),
    ?assertEqual(F, gen_server:call(ns_config, {update_with_changes, F})).

-define(assertConfigEquals(A, B), ?assertEqual(lists:ukeysort(1, A),
                                               lists:ukeysort(1, B))).

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
    {[{test, 1}], Val2} = Updater0([{foo, 2}]),
    ?assertConfigEquals([{test, 1}, {foo, 2}], Val2),

    {[{test, 1}], Val3} = Updater0([{foo, [{k, 1}, {v, 2}]},
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
    ?assertMatch([{test, SetVal1Actual1}], Val4),
    ok.

test_update_config() ->
    ?assertEqual([{test, 1}], update_config_key(test, 1, [])),
    ?assertEqual([{test, 1},
                  {foo, [{k, 1}, {v, 2}]},
                  {xar, true}],
                 update_config_key(test, 1, [{foo, [{k, 1}, {v, 2}]},
                                             {xar, true},
                                             {test, [{a, b}, {c, d}]}])).

test_set_kvlist() ->
    {NewPairs, [{foo, FooVal},
                {bar, false},
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

    ?assertEqual(-3, proplists:get_value(a, NewConfig)),
    ?assertEqual(-4, proplists:get_value(b, NewConfig)),

    ns_config:update_key(a, fun (3) -> 10 end),
    Updater2 = RecvUpdater(),
    {[{a, 10}], NewConfig2} = Updater2(OldConfig),

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
    Parent = self(),
    %% we don't want to kill this process when ns_config server dies,
    %% but we wan't to kill ns_config process when this process dies
    spawn(fun () ->
                  Cfg = #config{dynamic = [[{a, [{b, 1}, {c, 2}]},
                                            {d, 3}]],
                                policy_mod = ns_config_default,
                                saver_mfa = {?MODULE, send_config, [save_config_target]}},
                  {ok, _} = ns_config:start_link({with_state,
                                                  Cfg}),
                  MRef = erlang:monitor(process, Parent),
                  receive
                      {'DOWN', MRef, _, _, _} ->
                          ?debugFmt("Commiting suicide~n", []),
                          exit(death)
                  end
          end).

kill_and_wait(undefined) -> ok;
kill_and_wait(Pid) ->
    (catch erlang:unlink(Pid)),
    exit(Pid, kill),
    MRef = erlang:monitor(process, Pid),
    receive
        {'DOWN', MRef, _, _, _} -> ok
    end.

teardown_with_saver(_) ->
    kill_and_wait(whereis(ns_config)),
    kill_and_wait(whereis(ns_config_events)),
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
                               Cfg1 = ns_config:get(),
                               ?assertEqual(false, Cfg1#config.pending_more_save),

                               %% send last mutation
                               ns_config:set(d, 10),

                               %% check that pending_more_save is false
                               Cfg2 = ns_config:get(),
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
    Cfg1 = ns_config:get(),
    ?assertEqual(true, Cfg1#config.pending_more_save),

    %% now signal save completed
    Pid1 ! {Ref1, ok},

    %% expect second save request immediately
    {_, Ref2, Pid2} = receive
                          {saving, R1, C1, P1} -> {C1, R1, P1}
                      end,

    Cfg2 = ns_config:get(),
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

-endif.
