% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
% Copyright (c) 2009, NorthScale, Inc
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

-module(stream).

-define(CHUNK_SIZE, 5120).

%% API
-export([send/3, recv/3]).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/stream_test.erl").
-endif.

recv(Pid, Ref, Timeout) ->
  receive
    {Pid, Ref, {context, Context}} -> recv(Pid, Ref, Timeout, {Context, []})
  after
    Timeout -> {error, timeout}
  end.

recv(Pid, Ref, Timeout, {Context, Values}) ->
  receive
    {Pid, Ref, start_value} ->
      case recv_value(Pid, Ref, Timeout, <<0:0>>) of
        {error, timeout} -> {error, timeout};
        Value -> recv(Pid, Ref, Timeout, {Context, [Value|Values]})
      end;
    {Pid, Ref, eof} ->
      {ok, {Context, lists:reverse(Values)}}
  after
    Timeout -> {error, timeout}
  end.

recv_value(Pid, Ref, Timeout, Bin) ->
  receive
    {Pid, Ref, {data, Data}} -> recv_value(Pid, Ref, Timeout,
                                           <<Bin/binary, Data/binary>>);
    {Pid, Ref, end_value} -> Bin
  after
    Timeout -> {error, timeout}
  end.

send(RemotePid, Ref, {Context, Values}) ->
  RemotePid ! {self(), Ref, {context, Context}},
  send(RemotePid, Ref, Values);

send(RemotePid, Ref, []) ->
  RemotePid ! {self(), Ref, eof};

send(RemotePid, Ref, [Val|Values]) ->
  RemotePid ! {self(), Ref, start_value},
  send_value(RemotePid, Ref, Val, 0),
  send(RemotePid, Ref, Values).

send_value(RemotePid, Ref, Bin, Skip) when Skip >= byte_size(Bin) ->
  RemotePid ! {self(), Ref, end_value};

send_value(RemotePid, Ref, Bin, Skip) ->
  if
    (Skip + ?CHUNK_SIZE) > byte_size(Bin) ->
      <<_:Skip/binary, Chunk/binary>> = Bin;
    true ->
      <<_:Skip/binary, Chunk:?CHUNK_SIZE/binary, _/binary>> = Bin
  end,
  RemotePid ! {self(), Ref, {data, Chunk}},
  send_value(RemotePid, Ref, Bin, Skip + ?CHUNK_SIZE).

