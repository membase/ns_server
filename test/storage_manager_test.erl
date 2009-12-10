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

-compile(export_all).

all_test_() ->
  {foreach,
    fun() -> test_setup() end,
    fun(V) -> test_teardown(V) end,
    [
      {"test_initial_load", ?_test(test_initial_load())},
      {"test_reload_same_layout", ?_test(test_reload_same_layout())},
      {"test_loadout_change", ?_test(test_loadout_change())},
% TODO:
%      {"test_loadout_change_with_bootstrap",
%       ?_test(test_loadout_change_with_bootstrap())},
      {"test_unload_servers", ?_test(test_unload_servers())}
    ]}.

test_initial_load() ->
  Partitions = partition:create_partitions(1, node(), [node()]),
  expect_start_servers([storage_1, storage_2147483649]),
  storage_manager:load(node(), Partitions,
                       lists:map(fun({_,P}) -> P end, Partitions)),
  verify().

test_reload_same_layout() ->
  Partitions = partition:create_partitions(1, node(), [node()]),
  expect_start_servers([storage_1, storage_2147483649]),
  storage_manager:load(node(), Partitions,
                       lists:map(fun({_,P}) -> P end, Partitions)),
  % should not trigger any reload behavior
  storage_manager:load(node(), Partitions,
                       lists:map(fun({_,P}) -> P end, Partitions)),
  verify().

test_loadout_change() ->
  Partitions = partition:create_partitions(0, a, [a]),
  P2 = partition:create_partitions(1, a, [a]),
  expect_start_servers([storage_1]),
  storage_manager:load(a, Partitions, [1]),
  verify(),
  expect_start_servers([storage_2147483649]),
  storage_manager:load(a, P2, [1, 2147483649]),
  verify().

test_loadout_change_with_bootstrap() ->
  P1 = partition:create_partitions(1, a, [a, b]),
  P2 = partition:create_partitions(1, a, [a]),
  expect_start_servers([storage_1,storage_2147483649]),
  mock:expects(bootstrap, start,
               fun({_, Node, _}) -> Node == b end,
               fun({_, _, CB}, _) -> CB() end),
  storage_manager:load(a, P1, [1]),
  storage_manager:load(b, P2, [1, 2147483649]),
  verify().

test_unload_servers() ->
  P1 = partition:create_partitions(1, a, [a]),
  P2 = partition:create_partitions(1, a, [a, b]),
  expect_start_servers([storage_1,storage_2147483649]),
  expect_stop_servers([storage_2147483649]),
  storage_manager:load(b, P1, [1, 2147483649]),
  storage_manager:load(a, P2, [1]),
  verify().

test_setup() ->
  process_flag(trap_exit, true),
  config:start_link({config,
                     [{n,0},{r,1},{w,1},{q,6},{directory,priv_dir()}]}),
  {ok, _} = mock:mock(supervisor),
  {ok, _} = mock:mock(bootstrap),
  {ok, _} = storage_manager:start_link().

verify() ->
  ok = mock:verify(supervisor),
  ok = mock:verify(bootstrap).

test_teardown(_) ->
  storage_manager:stop(),
  mock:stop(supervisor),
  mock:stop(bootstrap).

priv_dir() ->
  Dir = filename:join([t:config(priv_dir), "data", "storage_manager"]),
  filelib:ensure_dir(filename:join(Dir, "storage_manager")),
  Dir.

expect_start_servers([]) -> ok;

expect_start_servers([Part|Parts]) ->
  mock:expects(supervisor, start_child,
               fun({storage_server_sup, Spec}) ->
                       element(1, Spec) == Part
               end, ok),
  expect_start_servers(Parts).

expect_stop_servers([]) -> ok;

expect_stop_servers([Part|Parts]) ->
  mock:expects(supervisor, terminate_child,
               fun({storage_server_sup, Name}) ->
                       Name == Part
               end, ok),
  mock:expects(supervisor, delete_child,
               fun({storage_server_sup, Name}) ->
                       Name == Part
               end, ok),
  expect_stop_servers(Parts).
