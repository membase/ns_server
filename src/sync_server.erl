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

-module(sync_server).

%% API

-export([start_link/2, pause/1, play/1, loop/1]).

-record(state, {name, partition, paused}).

start_link(Name, Partition) ->
  Pid = proc_lib:spawn_link(fun() ->
      sync_server:loop(#state{name=Name,partition=Partition,paused=false})
    end),
  register(Name, Pid),
  {ok, Pid}.

pause(Server) ->
  Server ! pause.

play(Server) ->
  Server ! play.

%% Internal functions

loop(State = #state{name=_Name,partition=Partition,paused=Paused}) ->
  Timeout = round((random:uniform() * 0.5 + 1) * 3600000),
  Paused1 = receive
    pause -> true;
    play -> false
  after Timeout ->
    Paused
  end,
  if
    Paused -> ok;
    true ->
      Nodes = membership:nodes_for_partition(Partition),
      (catch run_sync(Nodes, Partition))
  end,
  sync_server:loop(State#state{paused=Paused1}).

run_sync(Nodes, _) when length(Nodes) == 1 ->
  noop;

run_sync(Nodes, Partition) ->
  [NodeA,NodeB|_] = misc:shuffle(Nodes),
  StorageName = list_to_atom(lists:concat([storage_, Partition])),
  sync_manager:sync(Partition, NodeA, NodeB),
  storage_server:sync({StorageName, NodeA}, {StorageName, NodeB}),
  sync_manager:done(Partition).
