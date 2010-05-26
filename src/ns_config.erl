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

-define(DEFAULT_TIMEOUT, 500).

-export([start_link/2, start_link/1,
         get_remote/1, set_remote/2, set_remote/3,
         get/2, get/1, get/0, set/2, set/1, set/3,
         update/2,
         search/2, search/1,
         search_prop/3, search_prop/4,
         search_prop_tuple/3, search_prop_tuple/4,
         search_raw/2,
         clear/0, clear/1,
         proplist_get_value/3]).

% Exported for tests only
-export([strip_metadata/2, merge_configs/3, save_file/3, load_config/3,
         load_file/2, save_config/2]).

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

set_remote(Node, KVList) ->
    set_remote(Node, KVList, ?DEFAULT_TIMEOUT).
set_remote(Node, KVList, Timeout) ->
    gen_server:call({?MODULE, Node}, {merge, KVList}, Timeout).

get_remote(Node) -> config_dynamic(?MODULE:get(Node)).

% ----------------------------------------

set(Key, PropList, Timestamp) ->
    PropList2 = [{?METADATA_VER, Timestamp} |
                 strip_metadata(PropList, [])],
    gen_server:call(?MODULE, {merge, [{Key, PropList2}]}).

set(Key, PropList) when is_list(PropList) ->
    set(Key, PropList, erlang:now());

set(Key, Val)         -> gen_server:call(?MODULE, {merge, [{Key, Val}]}).
set(KVList)           -> gen_server:call(?MODULE, {merge,   KVList}).
replace(KVList)       -> gen_server:call(?MODULE, {replace, KVList}).
update(Fun, Sentinal) -> gen_server:call(?MODULE, {update, Fun, Sentinal}).

clear() -> clear([]).
clear(Keep) -> gen_server:call(?MODULE, {clear, Keep}).

% ----------------------------------------

% Returns an opaque Config object that's a snapshot of the configuration.
% The Config object can be passed to the search*() related set
% of functions.

get()              -> gen_server:call(?MODULE, get).
get(Node)          -> ?MODULE:get(Node, ?DEFAULT_TIMEOUT).
get(Node, Timeout) -> gen_server:call({?MODULE, Node}, get, Timeout).

% ----------------------------------------

search(Key) -> search(?MODULE:get(), Key).

search(Config, Key) ->
    case search_raw(Config, Key) of
        false      -> false;
        {value, X} -> {value, strip_metadata(X, [])}
    end.

% Returns the Value or undefined.

search_prop(Config, Key, SubKey) ->
    search_prop(Config, Key, SubKey, undefined).

% Returns the Value or the DefaultSubVal.

search_prop(Config, Key, SubKey, DefaultSubVal) ->
    case search(Config, Key) of
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

% Removes metadata like METADATA_VER from results.

strip_metadata([], Acc)                       -> lists:reverse(Acc);
strip_metadata([{?METADATA_VER, _} | T], Acc) -> strip_metadata(T, Acc);
strip_metadata([X | T], Acc)                  -> strip_metadata(T, [X | Acc]);
strip_metadata(X, _)                          -> X.

%% gen_server callbacks

init({full, ConfigPath, DirPath, PolicyMod} = Init) ->
    case load_config(ConfigPath, DirPath, PolicyMod) of
        {ok, Config} ->
            {ok, Config#config{init = Init}};
        Error ->
            {stop, Error}
    end;

init([ConfigPath, PolicyMod]) ->
    init({full, ConfigPath, undefined, PolicyMod}).

terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_cast(stop, State)            -> {stop, shutdown, State}.
handle_info(_Info, State)           -> {noreply, State}.

handle_call(reload, _From, State) ->
    case init(State#config.init) of
        {ok, State2}  -> {reply, ok, State2};
        {stop, Error} -> ns_log:log(?MODULE, 0001, "reload failed: ~p",
                                    [Error]),
                         {reply, {error, Error}, State}
    end;

handle_call(resave, _From, State) ->
    case save_config(State) of
        ok    -> {reply, ok, State};
        Error -> ns_log:log(?MODULE, 0002, "resave failed: ~p", [Error]),
                 {reply, Error, State}
    end;

handle_call(reannounce, _From, State) ->
    announce_changes(config_dynamic(State)),
    {reply, ok, State};

handle_call(get, _From, State) -> {reply, State, State};

handle_call({replace, KVList}, _From, State) ->
    {reply, ok, State#config{dynamic = [KVList]}};

handle_call({update, Fun, Sentinel}, From, State) ->
    UpdateFun = fun(Pair) ->
                        case Fun(Pair) of
                            Pair -> Pair;
                            Sentinel -> Sentinel;
                            {K, Data} ->
                                NewData = [{?METADATA_VER, erlang:now()} |
                                           strip_metadata(Data, [])],
                                error_logger:info_msg("Atomic update of ~p from ~p to ~p~n",
                                                      [K, element(2, Pair), NewData]),
                                {K, NewData}
                        end
                end,

    NewList = misc:mapfilter(UpdateFun, Sentinel, config_dynamic(State)),
    handle_call(resave, From, State#config{dynamic=[NewList]});

handle_call({clear, Keep}, From, State) ->
    NewList = lists:filter(fun({K,_V}) -> lists:member(K, Keep) end,
                           config_dynamic(State)),
    handle_call(resave, From, State#config{dynamic=[NewList]});

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
                    DynOld = config_dynamic(State),
                    DynNew = config_dynamic(State3),
                    DynChg = lists:subtract(DynNew, DynOld),
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
            {ok, #config{static = [S, DefaultConfig],
                         dynamic = D,
                         policy_mod = PolicyMod}};
        E -> E
    end.

save_config(Config) ->
    {value, DirPath} = search(Config, directory),
    save_config(Config, DirPath).

save_config(#config{dynamic = D}, DirPath) ->
    C = dynamic_config_path(DirPath),
    % Only saving the dynamic config parts.
    ok = save_file(bin, C, D).

announce_changes([]) -> ok;
announce_changes(KVList) ->
    % Fire a event per changed key.
    lists:foreach(fun ({Key, Value}) ->
                      gen_event:notify(ns_config_events,
                                       {Key, strip_metadata(Value, [])})
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
    RVer = misc:time_to_epoch_float(
             proplists:get_value(?METADATA_VER, RV)),
    LVer = misc:time_to_epoch_float(
             proplists:get_value(?METADATA_VER, LV)),
    case {RVer, LVer} of
        {undefined, undefined} -> [{Field, RV} | Acc];
        {_,         undefined} -> [{Field, RV} | Acc];
        {undefined, _}         -> [{Field, LV} | Acc];
        {RTime, LTime} when is_float(RTime),
                            is_float(LTime) ->
            case RTime > LTime of
                true  -> [{Field, RV} | Acc];
                false -> [{Field, LV} | Acc]
            end
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

