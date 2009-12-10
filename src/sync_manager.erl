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

-module(sync_manager).

-behaviour(gen_server).

%% API
-export([start_link/0, stop/0, load/3, loaded/0, sync/5, done/1,
         running/0, running/1, diffs/0, diffs/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {running,
                diffs,
                partitions=[],
                parts_for_node=[]}).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/sync_manager_test.erl").
-endif.

%% API

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
  gen_server:cast(?MODULE, stop).

load(Nodes, Partitions, PartsForNode) ->
  gen_server:call(?MODULE, {load, Nodes, Partitions, PartsForNode},
                  infinity).

sync(Part, Master, NodeA, NodeB, DiffSize) ->
  gen_server:cast(?MODULE, {sync, Part, Master, NodeA, NodeB, DiffSize}).

done(Part) ->
  gen_server:cast(?MODULE, {done, Part}).

running() ->
  gen_server:call(?MODULE, running).

running(Node) ->
  gen_server:call({?MODULE, Node}, running).

diffs() ->
  gen_server:call(?MODULE, diffs).

diffs(Node) ->
  gen_server:call({?MODULE, Node}, diffs).

loaded() ->
  gen_server:call(?MODULE, loaded).

%% gen_server callbacks

init([]) -> {ok, #state{running=[],diffs=[]}}.
terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_info(_Info, State)           -> {noreply, State}.

handle_call(loaded, _From, State) ->
  {reply, sync_server_sup:sync_servers(), State};

handle_call(running, _From, State = #state{running=Running}) ->
  {reply, Running, State};

handle_call(diffs, _From, State = #state{diffs=Diffs}) ->
  {reply, Diffs, State};

handle_call({load, _Nodes, NewPartitions, NewPartsForNode}, _From,
            State = #state{partitions=_OldPartitions,
                           parts_for_node=OldPartsForNode}) ->
  NewPartitions1 = lists:filter(fun (E) ->
                                    not lists:member(E, OldPartsForNode)
                                end, NewPartsForNode),
  OldPartitions1 = lists:filter(fun (E) ->
                                    not lists:member(E, NewPartsForNode)
                                end, OldPartsForNode),
  reload_sync_servers(OldPartitions1, NewPartitions1),
  {reply, ok, State#state{partitions=NewPartitions,
                          parts_for_node=NewPartsForNode}}.

handle_cast({sync, Part, Master, NodeA, NodeB, DiffSize},
            State = #state{running=Running,
                           diffs=Diffs}) ->
  NewDiffs = store_diff(Part, Master, NodeA, NodeB, DiffSize, Diffs),
  NewRunning = lists:keysort(1, lists:keystore(Part, 1, Running,
                                               {Part, NodeA, NodeB})),
  {noreply, State#state{running=NewRunning,diffs=NewDiffs}};

handle_cast({done, Part}, State = #state{running=Running}) ->
  NewRunning = lists:keydelete(Part, 1, Running),
  {noreply, State#state{running=NewRunning}};

handle_cast(stop, State) ->
  {stop, shutdown, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

reload_sync_servers(OldParts, NewParts) ->
  lists:foreach(fun(E) ->
      Name = list_to_atom(lists:concat([sync_, E])),
      supervisor:terminate_child(sync_server_sup, Name),
      supervisor:delete_child(sync_server_sup, Name)
    end, OldParts),
  lists:foreach(fun(Part) ->
      Name = list_to_atom(lists:concat([sync_, Part])),
      Spec = {Name, {sync_server, start_link, [Name, Part]},
              permanent, 1000, worker, [sync_server]},
      case supervisor:start_child(sync_server_sup, Spec) of
        already_present -> supervisor:restart_child(sync_server_sup, Name);
        _               -> ok
      end
    end, NewParts).

store_diff(Part, Master, Master, NodeB, DiffSize, Diffs) ->
  store_diff(Part, Master, NodeB, DiffSize, Diffs);

store_diff(Part, Master, NodeA, Master, DiffSize, Diffs) ->
  store_diff(Part, Master, NodeA, DiffSize, Diffs);

store_diff(_Part, _Master, _NodeA, _NodeB, _DiffSize, Diffs) ->
  Diffs.

store_diff(Part, _Master, Node, DiffSize, Diffs) ->
  case lists:keysearch(Part, 1, Diffs) of
    {value, {Part, DiffSizes}} ->
          lists:keystore(Part, 1, Diffs,
                         {Part,
                          lists:keystore(Node, 1, DiffSizes,
                                         {Node, DiffSize})
                         });
    false ->
          lists:keystore(Part, 1, Diffs, {Part, [{Node, DiffSize}]})
  end.
