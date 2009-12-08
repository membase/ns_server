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

-include_lib("eunit/include/eunit.hrl").

-define(MEG, 1048576).

simple_streaming_test() ->
  Bits = ?MEG*8,
  Bin = <<0:Bits>>,
  ?MEG = byte_size(Bin),
  Ref = make_ref(),
  Parent = self(),
  process_flag(trap_exit, true),
  Receiver = spawn_link(fun() ->
      receive
        {Ref, Sender} ->
          Results = recv(Sender, Ref, 1000),
          Parent ! {Ref, Results}
      end
    end),
  Sender = spawn_link(fun() ->
      send(Receiver, Ref, {context, [Bin]})
    end),
  Receiver ! {Ref, Sender},
  {ok, {context, [Bin]}} = receive
    {Ref, Results} -> Results
  end,
  receive
    {'EXIT', Receiver, _} -> ok
  end,
  receive
    {'EXIT', Sender, _} -> ok
  end.
