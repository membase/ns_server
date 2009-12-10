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

-module(emoxi_app).

-behaviour(application).

-export([start/2, stop/1]).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Application callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% @spec start(Type, StartArgs) -> {ok, Pid} |
%%                                 {ok, Pid, State} |
%%                                 {error, Reason}
%% @doc This function is called whenever an application
%% is started using application:start/1,2, and should start the processes
%% of the application. If the application is structured according to the
%% OTP design principles as a supervision tree, this means starting the
%% top supervisor of the tree.
%% @end
%%--------------------------------------------------------------------

start(_Type, []) ->
  case application:get_env(pidfile) of
      {ok, Location} ->
          Pid = os:getpid(),
          ok = file:write_file(Location, list_to_binary(Pid));
      undefined -> ok
  end,
  case application:get_env(config) of
    {ok, ConfigFile} ->
      case filelib:is_file(ConfigFile) of
        true  -> join_and_start(ConfigFile);
        false -> {error, io:format("~p does not exist.~n", [ConfigFile])}
      end;
    undefined ->
      {error, io:format("No config file given.~n", [])}
  end.

stop({_, Sup}) ->
  exit(Sup, shutdown),
  ok.

%%====================================================================

join_and_start(ConfigFile) ->
  case application:get_env(jointo) of
    {ok, NodeName} ->
      NN = [NodeName],
      io:format("attempting to contact ~p~n", NN),
      case net_adm:ping(NodeName) of
        pong ->
          io:format("Connected to ~p~n", NN),
          emoxi_sup:start_link(ConfigFile);
        pang ->
          {error, io:format("Could not connect to ~p. Exiting.", [NN])}
      end;
    undefined -> emoxi_sup:start_link(ConfigFile)
  end.
