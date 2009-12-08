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

relative_path_test() ->
  Dir = "/blah/blaa/bloo/blee/1/",
  File = "/bleep/bloop/blop/blorp/1/file.idx",
  ?assertEqual("/blah/blaa/bloo/blee/1/file.idx", relative_path(Dir, File)).

simple_send_test_() ->
  {timeout, 120, ?_test(test_simple_send())}.

test_simple_send() ->
  process_flag(trap_exit, true),
  test_cleanup(),
  test_setup(),
  Ref = make_ref(),
  Receiver = spawn_link(fun() -> receive_bootstrap(priv_dir("b"), Ref) end),
  send_bootstrap(priv_dir("a"), Receiver, Ref),
  ?assertEqual(file:read_file(data_file("a")), file:read_file(data_file("b"))).

test_cleanup() ->
  rm_rf_dir(priv_dir("a")),
  rm_rf_dir(priv_dir("b")).

test_setup() ->
  ok = crypto:start(),
  {ok, IO} = file:open(data_file("a"), [raw, binary, write]),
  lists:foreach(fun(_) ->
      D = << << X:8 >> || X <- lists:seq(1, 1024) >>,
      file:write(IO, D)
    end, lists:seq(1, 100)),
  ok = file:close(IO).

priv_dir(Root) ->
  Dir = filename:join([t:config(priv_dir), "bootstrap", Root, "1"]),
  filelib:ensure_dir(filename:join([Dir, "bootstrap"])),
  Dir.

data_file(Root) ->
  filename:join([priv_dir(Root), "bootstrap"]).

rm_rf_dir(Dir) ->
  ?cmd("rm -rf " ++ Dir).
