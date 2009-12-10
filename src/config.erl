% Copyright (c) 2009, NorthScale, Inc
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

-module(config).

-behaviour(gen_server).

-export([start_link/1, stop/0,
         get/2, get/1, get/0, set/2, set/1,
         search/2]).

% A static config file is often hand edited.
% potentially with in-line manual comments.
%
% A dynamic config file is system generated and modified,
% such as due to changes from UI/admin-screen operations, or
% nodes getting added/removed, and gossiping about config
% information.
%
-record(config, {static = [], % List of TupleList's.  TupleList is {K, V}.
                 dynamic = [] % List of TupleList's.  TupleList is {K, V}.
                }).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/config_test.erl").
-endif.

%% API

start_link(InitInfo) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, InitInfo, []).

stop() -> gen_server:cast(?MODULE, stop).

set(Key, Val) -> ?MODULE:set([{Key, Val}]).
set(KVList)   -> gen_server:call(?MODULE, {set, KVList}).

get()              -> gen_server:call(?MODULE, get).
get(Node)          -> ?MODULE:get(Node, 500).
get(Node, Timeout) -> gen_server:call({?MODULE, Node}, get, Timeout).

search(undefined, _Key) -> false;
search([], _Key)        -> false;
search([KVList | Rest], Key) ->
    case lists:keysearch(Key, 1, KVList) of
        {value, {Key, V}} -> {value, V};
        _                 -> search(Rest, Key)
    end;
search(#config{dynamic = DL, static = SL}, Key) ->
    case search(DL, Key) of
        {value, _} = R -> R;
        false          -> search(SL, Key)
    end.

mergable() ->
    [n, r, w, q, storage_mod, blocksize, buffered_writes].

%% gen_server callbacks

init(undefined) -> % Useful for unit-testing.
    {ok, #config{static = [config_default:default()]}};

init({config, D}) -> % Useful for unit-testing.
    {ok, #config{static = [config_default:default()], dynamic = [D]}};

init(ConfigPath) ->
    case load_config(ConfigPath) of
        {ok, Config} ->
            % TODO: Should save the merged dynamic file config.
            {ok, pick_node_and_merge(Config, nodes([visible]))};
        Error ->
            {stop, Error}
    end.

terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_cast(stop, State)            -> {stop, shutdown, State}.
handle_info(_Info, State)           -> {noreply, State}.

handle_call(get, _From, State) -> {reply, State, State};

handle_call({set, KVList}, _From, State) ->
    State2 = merge_configs(#config{dynamic = [KVList]}, State),
    save_config(State2),
    {reply, ok, State2}.

%%--------------------------------------------------------------------

load_config(ConfigPath) ->
    load_config(ConfigPath, undefined).

load_config(ConfigPath, DirPath) ->
    DefaultConfig = config_default:default(),
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
            ok = filelib:ensure_dir(DirPath2),
                                                % Dynamic config file.
            D = case load_file(bin, filename:join(DirPath2, "dynamic.cfg")) of
                    {ok, DRead} -> DRead;
                    _           -> []
                end,
            {ok, #config{static = [S, DefaultConfig], dynamic = D}};
        E -> E
    end.

save_config(Config) ->
    {value, DirPath} = search(Config, directory),
    save_config(Config, DirPath).

save_config(#config{dynamic = D}, DirPath) ->
    ok = filelib:ensure_dir(DirPath),
    % Only saving the dynamic config parts.
    ok = save_file(bin, filename:join(DirPath, "dynamic.cfg"), D).

load_file(txt, ConfigPath) -> file:consult(ConfigPath);

load_file(bin, ConfigPath) ->
    case file:read_file(ConfigPath) of
        {ok, B} -> {ok, binary_to_term(B)};
        _       -> not_found
    end.

save_file(bin, ConfigPath, X) ->
    {ok, F} = file:open(ConfigPath, [write, raw]),
    ok = file:write(F, term_to_binary(X)),
    ok = file:close(F).

pick_node_and_merge(Local, Nodes) when length(Nodes) == 0 -> Local;
pick_node_and_merge(Local, Nodes) ->
    [Node | _] = misc:shuffle(Nodes),
    case (catch ?MODULE:get(Node)) of
        {'EXIT', _, _} -> Local;
        {'EXIT', _}    -> Local;
        Remote         -> merge_configs(Remote, Local)
    end.

merge_configs(Remote, Local) ->
    merge_configs(mergable(), Remote, Local, []).

merge_configs(Mergable, Remote, Local) ->
    merge_configs(Mergable, Remote, Local, []).

merge_configs([], _Remote, Local, []) ->
    Local#config{dynamic = []};
merge_configs([], _Remote, Local, Acc) ->
    Local#config{dynamic = [lists:reverse(Acc)]};
merge_configs([Field | Fields], Remote, Local, Acc) ->
    RS = search(Remote, Field),
    LS = search(Local, Field),
    A2 = case {RS, LS} of
             {{value, RV}, _} -> [{Field, RV} | Acc];
             {_, {value, LV}} -> [{Field, LV} | Acc];
             _                -> Acc
         end,
    merge_configs(Fields, Remote, Local, A2).
