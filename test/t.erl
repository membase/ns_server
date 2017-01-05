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

-export([start/0, config/1]).

start() ->
    fake_loggers(),
    setup_paths(),

    io:format("Running tests~n", []),
    Ext = code:objfile_extension(),
    Wildcard = case os:getenv("T_WILDCARD") of
                   false -> "*";
                   X -> X
               end,
    FullWildcard =
        case lists:member($/, Wildcard) of
            true ->
                Wildcard ++ ".beam";
            false ->
                filename:join(["**", "ebin", Wildcard]) ++ ".beam"
        end,
    Files = filelib:wildcard(FullWildcard, config(root_dir)),
    Modules = lists:map(fun(BFN) ->
                                list_to_atom(filename:basename(BFN, Ext))
                        end,
                        Files),

    Listener = spawn_listener(),
    eunit:test(Modules, [verbose, {report, Listener}]),

    receive
        {failed_tests, FailedTests} ->
            handle_failed_tests(FailedTests)
    end.

%% create all the logger real ns_server has; this prevents failures if test
%% cases log something;
fake_loggers() ->
    ok = application:start(ale),

    ok = ale:start_sink(stderr, ale_stderr_sink, []),

    lists:foreach(
      fun (Logger) ->
              ok = ale:start_logger(Logger, debug),
              ok = ale:add_sink(Logger, stderr)
      end,
      ?LOGGERS).

setup_paths() ->
    Prefix = config(prefix_dir),
    BinDir = filename:join(Prefix, "bin"),

    Root = config(root_dir),
    TmpDir = filename:join(Root, "tmp"),
    file:make_dir(TmpDir),

    ets:new(path_config_override, [named_table, set, public]),
    ets:insert_new(path_config_override, {path_config_bindir, BinDir}),
    ets:insert_new(path_config_override, {path_config_tmpdir, TmpDir}),

    [ets:insert(path_config_override, {K, TmpDir})
     || K <- [path_config_tmpdir, path_config_datadir,
              path_config_libdir, path_config_etcdir]],
    ok.

spawn_listener() ->
    Parent = self(),
    proc_lib:spawn_link(fun () -> listener_loop(Parent, []) end).

listener_loop(Parent, FailedTests) ->
    receive
        {stop, _, _} ->
            Parent ! {failed_tests, FailedTests};
        {status, Id, {progress, 'begin', {test, TestProps}}} ->
            NewFailedTests = handle_test_progress(Id, TestProps, FailedTests),
            listener_loop(Parent, NewFailedTests);
        _ ->
            listener_loop(Parent, FailedTests)
    end.

handle_test_progress(Id, TestProps, FailedTests) ->
    receive
        {status, Id, Info} ->
            Failed =
                case Info of
                    {progress, 'end', {Result, _}} ->
                        Result =/= ok;
                    {cancel, _} ->
                        true
                end,

            case Failed of
                false ->
                    FailedTests;
                true ->
                    Source = proplists:get_value(source, TestProps),
                    [Source | FailedTests]
            end
    end.

handle_failed_tests([]) ->
    ok;
handle_failed_tests(FailedTests) ->
    io:format("=======================================================~n"),
    io:format("  ~s:~n", [bold_red("Failed tests")]),
    lists:foreach(
      fun ({Module, Function, Arity}) ->
              io:format("    ~s:~s/~b~n", [Module, Function, Arity])
      end, FailedTests),
    io:format("=======================================================~n").

bold_red(Text) ->
    [<<"\e[31;1m">>, Text, <<"\e[0m">>].

config(root_dir) ->
    filename:absname(filename:dirname(config(test_dir)));

config(ebin_dir) ->
    filename:absname(filename:join([config(root_dir), "ebin"]));

config(test_dir) ->
    filename:absname(filename:dirname(?FILE));

config(priv_dir) ->
    case init:get_argument(priv_dir) of
        {ok, [[Dir]]} ->
            Dir;
        _Other ->
            Root = config(test_dir),
            filename:absname(
              filename:join([Root, "log", atom_to_list(node())]))
    end;

config(prefix_dir) ->
    case init:get_argument(prefix_dir) of
        {ok, [[Prefix]]} ->
            Prefix;
        _ ->
            Root = config(root_dir),
            filename:absname(
              filename:join([Root, "..", "install"]))
    end.
