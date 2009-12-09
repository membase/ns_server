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

-include("mc_entry.hrl").

-export([start_link/1, get/2, get/1, get/0, set/1, stop/0]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link(ConfigPath) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, ConfigPath, []).

get(Node)          -> ?MODULE:get(Node, 500).
get(Node, Timeout) -> gen_server:call({?MODULE, Node}, get, Timeout).

get() ->
    case erlang:get(?MODULE) of
        undefined -> C = gen_server:call(?MODULE, get),
                     erlang:put(?MODULE, C),
                     C;
        C -> C
    end.

set(Config) ->
    gen_server:call(?MODULE, {set, Config}).

stop() ->
    erlang:erase(?MODULE),
    gen_server:cast(?MODULE, stop).

%% gen_server callbacks

init(Config = #config{}) ->
  Merged = pick_node_and_merge(Config, nodes([visible])),
  {ok, Merged};

init(ConfigPath) when is_list(ConfigPath) ->
  case read_file(ConfigPath) of
    {ok, Config} ->
      filelib:ensure_dir(Config#config.directory ++ "/"),
        _Merged = pick_node_and_merge(Config, nodes([visible])),
      {ok, Config};
    {error, Reason} -> {error, Reason}
  end.

terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_info(_Info, State)                 -> {noreply, State}.
handle_call(get, _From, State)            -> {reply, State, State};
handle_call({set, Config}, _From, _State) -> {reply, ok, Config}.
handle_cast(stop, State)                  -> {stop, shutdown, State}.

%%--------------------------------------------------------------------

pick_node_and_merge(Config, Nodes) when length(Nodes) == 0 -> Config;
pick_node_and_merge(Config, Nodes) ->
  [Node|_] = lib_misc:shuffle(Nodes),
  case (catch ?MODULE:get(Node)) of
    {'EXIT', _, _} -> Config;
    {'EXIT',_} -> Config;
    Remote -> merge_configs(Remote, Config)
  end.

merge_configs(Remote, Local) ->
  %we need to merge in any cluster invariants
  merge_configs([n, r, w, q, storage_mod, blocksize, buffered_writes], Remote, Local).

merge_configs([], _Remote, Merged) -> Merged;

merge_configs([Field|Fields], Remote, Merged) ->
  merge_configs(Fields, Remote,
                config_set(Field, Merged,
                           config_get(Field, Remote))).

read_file(ConfigPath) ->
    file:consult(ConfigPath).

config_get(Field, Tuple) ->
  config_get(record_info(fields, mc_config), Field, Tuple, 2).

config_get([], _, _, _) ->
  undefined;

config_get([Field | _], Field, Tuple, Index) ->
  element(Index, Tuple);

config_get([_ | Fields], Field, Tuple, Index) ->
  config_get(Fields, Field, Tuple, Index+1).

config_set(Field, Tuple, Value) ->
  config_set(record_info(fields, mc_config), Field, Tuple, Value, 2).

config_set([], _Field, Tuple, _, _) ->
  Tuple;

config_set([Field | _], Field, Tuple, Value, Index) ->
  setelement(Index, Tuple, Value);

config_set([_ | Fields], Field, Tuple, Value, Index) ->
  config_set(Fields, Field, Tuple, Value, Index + 1).
