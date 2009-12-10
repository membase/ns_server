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
% POSSIBILITY OF SUCH DAMAGE.-module(config).
%
% Original Author: Cliff Moon

-module(emoxi).

-export([start/0, running/1, running_nodes/0,
         pause_all_sync/0, start_all_sync/0]).

% erl -boot start_sasl -pa ebin -s emoxi start -emoxi config config.sample

start() ->
  crypto:start(),
  misc:load_start_apps(apps()).

apps() ->
  % [os_mon, emoxi].
    [emoxi].

running(Node) ->
  Ref = erlang:monitor(process, {membership, Node}),
  R = receive
          {'DOWN', Ref, _, _, _} -> false
      after 1 ->
          true
      end,
  erlang:demonitor(Ref),
  R.

running_nodes() ->
  [Node || Node <- erlang:nodes([this, visible]), running(Node)].

pause_all_sync() ->
  SyncServers = lists:flatten(lists:map(fun(Node) ->
      rpc:call(Node, sync_manager, loaded, [])
    end, running_nodes())),
  lists:foreach(fun(Server) ->
      sync_server:pause(Server)
    end, SyncServers).

start_all_sync() ->
  SyncServers = lists:flatten(lists:map(fun(Node) ->
      rpc:call(Node, sync_manager, loaded, [])
    end, running_nodes())),
  lists:foreach(fun(Server) ->
      sync_server:play(Server)
    end, SyncServers).


