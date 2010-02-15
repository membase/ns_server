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

-module(bootstrap).

-define(CHUNK, 4096).

-include_lib("eunit/include/eunit.hrl").

-include("common.hrl").

%% API
-export([start/3]).

-ifdef(TEST).
-include("test/bootstrap_test.erl").
-endif.

start(Directory, OldNode, Callback) when is_function(Callback) ->
  ?infoFmt("bootstrapping for directory ~p~n", [Directory]),
  Ref = make_ref(),
  Receiver = spawn_link(fun() ->
      receive_bootstrap(Directory, Ref),
      % start the node once we receive the data
      Callback()
    end),
  spawn_link(OldNode,
             fun() -> send_bootstrap(Directory, Receiver, Ref) end).

%%====================================================================

receive_bootstrap(Directory, Ref) ->
  receive
    {Ref, filename, Filename} ->
      File = relative_path(Directory, Filename),
      filelib:ensure_dir(File),
      receive_file(File, Ref),
      receive_bootstrap(Directory, Ref);
    {Ref, Pid, done} -> Pid ! {Ref, ok}
  end.

receive_file(File, Ref) ->
  {ok, IO} = file:open(File, [raw, binary, write]),
  Ctx = crypto:md5_init(),
  receive_contents(Ref, IO, Ctx).

receive_contents(Ref, IO, Ctx) ->
  receive
    {Ref, data, Data} ->
      file:write(IO, Data),
      receive_contents(Ref, IO, crypto:md5_update(Ctx, Data));
    {Ref, md5, Hash, Pid} ->
      case crypto:md5_final(Ctx) of
        Hash -> Pid ! {Ref, ok};
        _ -> Pid ! {Ref, error}
      end;
    {Ref, error, Reason} ->
      error_logger:info_msg("bootstrap receive failed with reason ~p~n",
                            [Reason]),
      exit(Reason);
    _ -> ok
  end.

send_bootstrap(Directory, Pid, Ref) ->
  filelib:fold_files(Directory, ".*", true, fun(File, _) ->
      send_file(File, Pid, Ref)
    end, nil),
  Pid ! {Ref, self(), done},
  receive
    {Ref, ok} -> ok % now we're done
  end.

send_file(File, Pid, Ref) ->
  Pid ! {Ref, filename, File},
  {ok, IO} = file:open(File, [raw, binary, read]),
  Ctx = crypto:md5_init(),
  send_contents(Ref, Pid, IO, Ctx),
  ok = file:close(IO),
  % receive_ok(File, Pid, Ref).
  receive
    {Ref, ok} -> ok;
    {Ref, error} -> send_file(File, Pid, Ref)
  end.

send_contents(Ref, Pid, IO, Ctx) ->
  case file:read(IO, ?CHUNK) of
    {ok, Data} ->
      Pid ! {Ref, data, Data},
      send_contents(Ref, Pid, IO, crypto:md5_update(Ctx, Data));
    eof ->
      Pid ! {Ref, md5, crypto:md5_final(Ctx), self()};
    {error, Reason} ->
      error_logger:info_msg("Bootstrap send failed with reason ~p~n",
                            [Reason]),
      Pid ! {Ref, error, Reason},
      exit(Reason)
  end.

relative_path(Directory, File) ->
  DirTokens = string:tokens(Directory, "/"),
  Dirname = lists:last(DirTokens),
  FileTokens = lists:takewhile(fun(T) ->
      T =/= Dirname
    end, lists:reverse(string:tokens(File, "/"))),
  Final = string:join(DirTokens ++ lists:reverse(FileTokens), "/"),
  case Directory of
    [$/ | _] -> "/" ++ Final;
    _ -> Final
  end.
