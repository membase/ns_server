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

-module(storage_manager).

-behaviour(gen_server).

%% API

-export([start_link/0, load/3, load_no_boot/3, loaded/0, stop/0]).

%% gen_server callbacks

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {partitions=[],parts_for_node=[]}).

-include("common.hrl").
-include("mc_entry.hrl").

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/storage_manager_test.erl").
-endif.

%% API

start_link() ->
  gen_server:start_link({local, storage_manager}, ?MODULE, [], []).

load(Nodes, Partitions, PartsForNode) ->
  gen_server:call(storage_manager, {load, Nodes, Partitions, PartsForNode, true}, infinity).

load_no_boot(Nodes, Partitions, PartsForNode) ->
  gen_server:call(storage_manager, {load, Nodes, Partitions, PartsForNode, false}, infinity).

loaded() ->
  gen_server:call(storage_manager, loaded).

stop() ->
  gen_server:cast(storage_manager, stop).

%% gen_server callbacks

init([]) -> {ok, #state{}}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_info(_Info, State) -> {noreply, State}.
handle_cast(stop, State) -> {stop, shutdown, State}.

handle_call(loaded, _From, State) ->
  {reply,
   [Name || {registered_name, Name} <-
                [erlang:process_info(Pid, registered_name) || Pid <-
                   storage_server_sup:storage_servers()]], State};

handle_call({load, _Nodes, Partitions, PartsForNode, Bootstrap},
            _From, #state{partitions=OldPartitions,
                          parts_for_node=OldPartsForNode}) ->
  Partitions1 = lists:filter(
                  fun(E) ->
                          not lists:member(E, OldPartsForNode)
                  end, PartsForNode),
  OldPartitions1 = lists:filter(
                     fun(E) ->
                             not lists:member(E, PartsForNode)
                     end, OldPartsForNode),
  Config = config:get(),
  % if
  %   length(OldPartitions) == 0 ->
  %     reload_storage_servers(OldPartitions1, Partitions1, Partitions,
  %                            Config);
  %   true ->
  reload_storage_servers(OldPartitions1, Partitions1, OldPartitions,
                         Config, Bootstrap),
  % end,
  {reply, ok, #state{partitions=Partitions,parts_for_node=PartsForNode}}.

%%--------------------------------------------------------------------

reload_storage_servers(OldParts, NewParts, Old, Config, Bootstrap) ->
  lists:foreach(fun(E) ->
      Name = list_to_atom(lists:concat([storage_, E])),
      supervisor:terminate_child(storage_server_sup, Name),
      supervisor:delete_child(storage_server_sup, Name)
    end, OldParts),
  lists:foreach(fun(Part) ->
    Name = list_to_atom(lists:concat([storage_, Part])),
    {value, Directory} = config:search(Config, directory),
    DbKey = lists:concat([Directory, "/", Part]),
    {value, BlockSize} = config:search(Config, blocksize),
    {value, Q} = config:search(Config, q),
    Size = partition:partition_range(Q),
    Min = Part,
    Max = Part+Size,
    {value, StorageMod} = config:search(Config, storage_mod),
    Spec = {Name, {storage_server,start_link,
                   [StorageMod, DbKey, Name,
                    Min, Max, BlockSize]},
            permanent, 1000, worker, [storage_server]},
    Callback = fun() ->
        % ?infoFmt("Starting the server for ~p~n", [Spec]),
        case supervisor:start_child(storage_server_sup, Spec) of
          already_present -> supervisor:restart_child(storage_server_sup,
                                                      Name);
          _ -> ok
        end
      end,
    case {lists:keysearch(Part, 2, Old), Bootstrap} of
      {{value, {OldNode, _}}, true} ->
        bootstrap:start(DbKey, OldNode, Callback);
      _ -> Callback()
    end
  end, NewParts).
