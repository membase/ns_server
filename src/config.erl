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
         val/1, get/2, get/1, get/0, set/1, set/2,
         search/2]).

% A static config file is often hand edited.
% potentially with in-line manual comments.
%
% A dynamic config file is updated due to the system,
% such as due to UI/admin-screen operations, or
% nodes getting added/removed, and gossiping about config
% information.
%
-record(config, {dynamic = [], % List of TupleList's.  TupleList is {K, V}.
                 static = []   % List of TupleList's.  TupleList is {K, V}.
                }).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link(X) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, X, []).

stop() -> gen_server:cast(?MODULE, stop).

val(Key) -> search(?MODULE:get(), Key).

set(Key, Val) -> % For testing, not concurrent safe.
    Config = ?MODULE:get(),
    set(Config#config{dynamic = [[{Key, Val}] | Config#config.dynamic]}).

get()              -> gen_server:call(?MODULE, get).
get(Node)          -> ?MODULE:get(Node, 500).
get(Node, Timeout) -> gen_server:call({?MODULE, Node}, get, Timeout).

set(Config) ->
    gen_server:call(?MODULE, {set, Config}).

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

%% gen_server callbacks

init(undefined) ->
    {ok, #config{static = [config_default:default()]}};

init({config, D}) ->
    {ok, #config{dynamic = [D], static = [config_default:default()]}};

init(ConfigPath) ->
    Config = read_file_config(ConfigPath),
    Merged = pick_node_and_merge(Config, nodes([visible])),
    % TODO: Should save the merged dynamic file config.
    {ok, Merged}.

terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_info(_Info, State)                 -> {noreply, State}.
handle_call(get, _From, State)            -> {reply, State, State};
handle_call({set, Config}, _From, _State) -> {reply, ok, Config}.
handle_cast(stop, State)                  -> {stop, shutdown, State}.

%%--------------------------------------------------------------------

read_file(ConfigPath) -> file:consult(ConfigPath).

read_file_config(ConfigPath) ->
    DefaultConfig = config_default:default(),
    % Static config file.
    {ok, S} = read_file(ConfigPath),
    % Dynamic data directory.
    {value, DirPath} = search([S, DefaultConfig], directory),
    ok = filelib:ensure_dir(DirPath),
    % Dynamic config file.
    D = case read_file(filename:join(DirPath, "dynamic.cfg")) of
            {ok, DRead} -> DRead;
            _           -> []
        end,
    #config{dynamic = [D],
            static  = [S, DefaultConfig]}.

pick_node_and_merge(Local, Nodes) when length(Nodes) == 0 -> Local;
pick_node_and_merge(Local, Nodes) ->
    [Node | _] = misc:shuffle(Nodes),
    case (catch ?MODULE:get(Node)) of
        {'EXIT', _, _} -> Local;
        {'EXIT', _}    -> Local;
        Remote         -> merge_configs(Remote, Local)
    end.

merge_configs(Remote, Local) ->
    % we need to merge in any cluster invariants
    merge_configs([n, r, w, q, storage_mod, blocksize, buffered_writes],
                  Remote, Local, []).

merge_configs([], _Remote, Local, Acc) ->
    Local#config{dynamic = [Acc]};

merge_configs([Field | Fields], Remote, Local, Acc) ->
    RS = search(Remote, Field),
    LS = search(Local, Field),
    A2 = case {RS, LS} of
             {{value, RV}, _} -> [{Field, RV} | Acc];
             {_, {value, LV}} -> [{Field, LV} | Acc];
             _                -> Acc
         end,
    merge_configs(Fields, Remote, Local, A2).
