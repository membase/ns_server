% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
% Copyright (c) 2009, NorthScale, Inc.
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

-module(t).

-include("ns_common.hrl").

-export([start/0, start_with_coverage/0, config/1]).

start() ->
    start_without_coverage().

%% create all the logger real ns_server has; this prevents failures if test
%% cases log something;
fake_loggers() ->
    ok = application:start(ale),
    ok = ale:start_logger(?NS_SERVER_LOGGER, debug),
    ok = ale:start_sink(stderr, ale_stderr_sink, []),
    ok = ale:add_sink(?NS_SERVER_LOGGER, stderr).

start_with_coverage() ->
    fake_loggers(),

    cover:compile_beam_directory(config(ebin_dir)),
    Modules = cover:modules(),
    Result = eunit:test(Modules, [verbose]),
    CovDir = config(cov_dir),
    misc:rm_rf(CovDir),
    file:make_dir(CovDir),
    lists:foreach(
      fun (M) ->
              cover:analyse_to_file(M, filename:join([CovDir, atom_to_list(M) ++
                                                          ".COVERAGE.html"]),
                                    [html])
      end, Modules),
    Result.

start_without_coverage() ->
    fake_loggers(),

    io:format("Running tests without coverage~n", []),
    Ext = code:objfile_extension(),
    Dir = config(ebin_dir),
    Wildcard = case os:getenv("T_WILDCARD") of
                   false -> "*";
                   X -> X
               end,
    Files = filelib:wildcard(Wildcard, Dir),
    BeamFileNames =
        lists:filter(fun (File) ->
                             case filename:extension(File) of
                                 Ext -> true;
                                 _ -> false
                             end
                     end,
                     Files),
    Modules = lists:map(fun(BFN) ->
                                list_to_atom(filename:basename(BFN, Ext))
                        end,
                        BeamFileNames),
    eunit:test(Modules, [verbose]).

config(cov_dir) ->
    filename:absname(filename:join([config(root_dir), "coverage"]));

config(root_dir) ->
    filename:dirname(config(test_dir));

config(ebin_dir) ->
    filename:absname(filename:join([config(root_dir), "ebin"]));

config(src_dir) ->
    filename:absname(filename:join([config(root_dir), "src"]));

config(test_dir) ->
    filename:dirname(?FILE);

config(priv_dir) ->
    case init:get_argument(priv_dir) of
        {ok, [[Dir]]} ->
            Dir;
        _Other ->
            Root = config(test_dir),
            filename:absname(
              filename:join([Root, "log", atom_to_list(node())]))
    end.

