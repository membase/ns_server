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

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

all_test_() ->
  {foreach,
    fun() -> test_setup() end,
    fun(V) -> test_teardown(V) end,
  [
    {"test_search_list",
     ?_test(test_search_list())},
    {"test_strip_metadata",
     ?_test(test_strip_metadata())},
    {"test_search_config",
     ?_test(test_search_config())},
    {"test_search_prop_config",
     ?_test(test_search_prop_config())},
    {"test_merge_config_static",
     ?_test(test_merge_config_static())},
    {"test_merge_config_dynamic",
     ?_test(test_merge_config_dynamic())},
    {"test_merge_config_ver",
     ?_test(test_merge_config_ver())},
    {"test_bin_persist",
     ?_test(test_bin_persist())},
    {"test_load_config_improper",
     ?_test(test_load_config_improper())},
    {"test_load_config",
     ?_test(test_load_config())},
    {"test_save_config",
     ?_test(test_save_config())},
    {"test_include_config",
     ?_test(test_include_config())},
    {"test_include_missing_config",
     ?_test(test_include_missing_config())},
    {"test_svc",
     ?_test(test_svc())}
  ]}.

test_search_list() ->
    ?assertMatch(false, search([], foo)),
    ?assertMatch(false, search([[], []], foo)),
    ?assertMatch(false, search([[{x, 1}]], foo)),
    ?assertMatch({value, 1}, search([[{x, 1}], [{x, 2}]], x)),
    ok.

test_strip_metadata() ->
    ?assertMatch(x, strip_metadata(x, [])),
    ?assertMatch([], strip_metadata([], [])),
    ?assertMatch([1, 2], strip_metadata([1, 2], [])),
    ?assertMatch([1, 2], strip_metadata([{?METADATA_VER, x}, 1, 2], [])),
    ?assertMatch([], strip_metadata([{?METADATA_VER, x}], [])),
    ok.

test_search_config() ->
    ?assertMatch(false,
                 search(#config{},
                        x)),
    ?assertMatch(false,
                 search(#config{dynamic = [[], []],
                                static = [[], []]},
                        x)),
    ?assertMatch({value, 1},
                 search(#config{dynamic = [[{x, 1}], [{x, 2}]],
                                static = []},
                        x)),
    ?assertMatch({value, 2},
                 search(#config{dynamic = [[{y, 1}], [{x, 2}]],
                                static = [[], []]},
                        x)),
    ?assertMatch({value, 3},
                 search(#config{dynamic = [[{y, 1}], [{x, 2}]],
                                static = [[{w, 4}], [{z, 3}]]},
                        z)),
    ?assertMatch({value, 2},
                 search(#config{dynamic = [[{y, 1}], [{z, 2}]],
                                static = [[{w, 4}], [{z, 3}]]},
                        z)),
    ?assertMatch({value, [{hi, there}]},
                 search(#config{dynamic = [[{y, 1}], [{z, [{hi, there}]}]],
                                static = [[{w, 4}], [{z, 3}]]},
                        z)),
    ?assertMatch({value, [{hi, there}]},
                 search(#config{dynamic = [[{y, 1}], [{z, [{'_ver', stripped},
                                                           {hi, there}]}]],
                                static = [[{w, 4}], [{z, 3}]]},
                        z)),
    ok.

test_search_prop_config() ->
    ?assertMatch(foo,
                 search_prop(#config{},
                             x, a, foo)),
    ?assertMatch(foo,
                 search_prop(#config{dynamic = [[], []],
                                     static = [[], []]},
                             x, a, foo)),
    ?assertMatch(foo,
                 search_prop(#config{dynamic = [[{x, []}], [{x, []}]],
                                     static = []},
                             x, a, foo)),
    ?assertMatch(foo,
                 search_prop(#config{dynamic = [[{x, [{b, bar}]}], [{x, []}]],
                                     static = []},
                             x, a, foo)),
    ?assertMatch(baz,
                 search_prop(#config{dynamic = [[{x, [{b, bar},
                                                      {a, baz}]}], [{x, []}]],
                                     static = []},
                             x, a, foo)),
    ?assertMatch(foo,
                 search_prop(#config{dynamic = [[{x, [{b, bar}]}],
                                                [{x, [{a, baz}]}]],
                                     static = []},
                             x, a, foo)),
    ok.

test_merge_config_static() ->
    Mergable = [x, y, z, rx, lx],
    ?assertEqual(
       #config{},
       merge_configs(Mergable,
         #config{},
         #config{})),
    X0 = #config{dynamic = [],
                 static = []},
    ?assertEqual(X0,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = []},
         #config{dynamic = [],
                 static = []})),
    X1 = #config{dynamic = [[{x,1}]],
                 static = [[{x,1}]]},
    ?assertEqual(X1,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = []},
         #config{dynamic = [],
                 static = [[{x,1}]]})),
    X2 = #config{dynamic = [[{rx,1},{lx,1}]],
                 static = [[{lx,1}]]},
    ?assertEqual(X2,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = [[{rx,1}]]},
         #config{dynamic = [],
                 static = [[{lx,1}]]})),
    X3 = #config{dynamic = [[{lx,2}]],
                 static = [[{lx,1}]]},
    ?assertEqual(X3,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = [[{lx,2}]]},
         #config{dynamic = [],
                 static = [[{lx,1}]]})),
    X4 = #config{dynamic = [[{rx,1},{lx,1}]],
                 static = [[{lx,1},{foo,9}]]},
    ?assertEqual(X4,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = [[{rx,1},{lx,1},{foo,10}]]},
         #config{dynamic = [],
                 static = [[{lx,1},{foo,9}]]})),
    ok.

test_merge_config_dynamic() ->
    Mergable = [x, y, z],
    X0 = #config{dynamic = [[{x,1},{y,1}]],
                 static = [[{x,1}]]},
    ?assertEqual(X0,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = []},
         #config{dynamic = [[{y,1}]],
                 static = [[{x,1}]]})),
    X1 = #config{dynamic = [[{x,1},{y,1}]],
                 static = [[{x,1}]]},
    ?assertEqual(X1,
       merge_configs(Mergable,
         #config{dynamic = [[{y,1}]],
                 static = []},
         #config{dynamic = [],
                 static = [[{x,1}]]})),
    X2 = #config{dynamic = [[{x,1},{y,1}]],
                 static = [[{x,1},{foo,9}]]},
    ?assertEqual(X2,
       merge_configs(Mergable,
         #config{dynamic = [[{y,1}]],
                 static = []},
         #config{dynamic = [[{y,2}]],
                 static = [[{x,1},{foo,9}]]})),
    X3 = #config{dynamic = [[{x,1},{y,1}]],
                 static = [[{x,1},{foo,9}]]},
    ?assertEqual(X3,
       merge_configs(Mergable,
         #config{dynamic = [[{y,1}]],
                 static = [[{foo,10}]]},
         #config{dynamic = [[{y,2}]],
                 static = [[{x,1},{foo,9}]]})),
    ok.

test_merge_config_ver() ->
    Mergable = [x, y, z],
    X0 = #config{dynamic = [[{x,1},
                             {y,[{?METADATA_VER,{0,0,1}}, yy]}]],
                 static = [[{x,1}]]},
    ?assertEqual(X0,
       merge_configs(Mergable,
         #config{dynamic = [],
                 static = []},
         #config{dynamic = [[{y,[{?METADATA_VER,{0,0,1}}, yy]}]],
                 static = [[{x,1}]]})),
    X2 = #config{dynamic = [[{x,1},{y,[{?METADATA_VER,{0,0,2}}, y2]}]],
                 static = [[{x,1},{foo,9}]]},
    ?assertEqual(X2,
       merge_configs(Mergable,
         #config{dynamic = [[{y,[{?METADATA_VER,{0,0,1}}, y1]}]],
                 static = []},
         #config{dynamic = [[{y,[{?METADATA_VER,{0,0,2}}, y2]}]],
                 static = [[{x,1},{foo,9}]]})),
    X3 = #config{dynamic = [[{x,[{?METADATA_VER,{0,1,2}}, x1]},
                             {y,[{?METADATA_VER,{0,0,2}}, y2]}]],
                 static = [[{x,1},{foo,9}]]},
    ?assertEqual(X3,
       merge_configs(Mergable,
         #config{dynamic = [[{x,[{?METADATA_VER,{0,1,2}}, x1]},
                             {y,[{?METADATA_VER,{0,0,1}}, y1]}]],
                 static = []},
         #config{dynamic = [[{y,[{?METADATA_VER,{0,0,2}}, y2]},
                             {x,[{?METADATA_VER,{0,1,1}}, x2]}]],
                 static = [[{x,1},{foo,9}]]})),
    ok.

test_bin_persist() ->
    CP = data_file(),
    D = [[{x,1},{y,2},{z,3}]],
    ?assertEqual(ok, save_file(bin, CP, D)),
    R = load_file(bin, CP),
    ?assertEqual({ok, D}, R),
    ok.

default() -> []. % For testing.

test_load_config_improper() ->
    CP = data_file(),
    {ok, F} = file:open(CP, [write, raw]),
    ok = file:write(F, <<"improper config file">>),
    ok = file:close(F),
    R = load_config(CP, test_dir(), ?MODULE),
    ?assertMatch({error, _}, R),
    ok.

test_load_config() ->
    CP = data_file(),
    {ok, F} = file:open(CP, [write, raw]),
    ok = file:write(F, <<"{x,1}.">>),
    ok = file:close(F),
    R = load_config(CP, test_dir(), ?MODULE),
    E = #config{static = [[{x,1}], []], policy_mod = ?MODULE},
    ?assertEqual({ok, E}, R),
    ok.

test_save_config() ->
    CP = data_file(),
    {ok, F} = file:open(CP, [write, raw]),
    ok = file:write(F, <<"{x,1}.">>),
    ok = file:close(F),
    R = load_config(CP, test_dir(), ?MODULE),
    E = #config{static = [[{x,1}], []], policy_mod = ?MODULE},
    ?assertMatch({ok, E}, R),
    X = E#config{dynamic = [[{x,2},{y,3}]], policy_mod = ?MODULE},
    ?assertEqual(ok, save_config(X, test_dir())),
    R2 = load_config(CP, test_dir(), ?MODULE),
    ?assertMatch({ok, X}, R2),
    ok.

test_svc() ->
    process_flag(trap_exit, true),
    CP = data_file(),
    D = test_dir(),
    B = <<"{x,1}.">>,
    {ok, F} = file:open(CP, [write, raw]),
    ok = file:write(F, B),
    ok = file:close(F),
    {ok, _ConfigPid} = ?MODULE:start_link({full, CP, D, ns_config_default}),
    (fun() ->
      C = ?MODULE:get(),
      R = ?MODULE:search(C, x),
      ?assertMatch({value, 1}, R),
      ok
     end)(),
    (fun() ->
      R = ?MODULE:search(x),
      ?assertMatch({value, 1}, R),
      ok
     end)(),
    (fun() ->
      R = ?MODULE:search(y),
      ?assertMatch(false, R),
      ok
     end)(),
    ?MODULE:stop(),
    ok.

test_include_config() ->
    CP1 = data_file(atom_to_list(node()) ++ "_one.cfg"),
    CP2 = data_file(atom_to_list(node()) ++ "_two.cfg"),
    {ok, F1} = file:open(CP1, [write, raw]),
    ok = file:write(F1, <<"{x,1}.\n">>),
    X = "{include,\"" ++ CP2 ++ "\"}.\n",
    ok = file:write(F1, list_to_binary(X)),
    ok = file:write(F1, <<"{y,1}.\n">>),
    ok = file:close(F1),
    {ok, F2} = file:open(CP2, [write, raw]),
    ok = file:write(F2, <<"{z,9}.">>),
    ok = file:close(F2),
    R = load_config(CP1, test_dir(), ?MODULE),
    E = #config{static = [[{x,1}, {z,9}, {y,1}], []], policy_mod = ?MODULE},
    ?assertEqual({ok, E}, R),
    ok.

test_include_missing_config() ->
    CP1 = data_file(atom_to_list(node()) ++ "_top.cfg"),
    {ok, F1} = file:open(CP1, [write, raw]),
    ok = file:write(F1, <<"{x,1}.\n">>),
    X = "{include,\"not_a_config_path\"}.\n",
    ok = file:write(F1, list_to_binary(X)),
    ok = file:write(F1, <<"{y,1}.\n">>),
    ok = file:close(F1),
    R = load_config(CP1, test_dir(), ?MODULE),
    ?assertEqual({error, {bad_config_path, "not_a_config_path"}}, R),
    ok.

test_setup() ->
    process_flag(trap_exit, true),
    misc:rm_rf(test_dir()),
    ok.

test_teardown(_) ->
    file:delete(data_file()),
    misc:rm_rf(test_dir()),
    ok.

test_dir() ->
  Dir = filename:join([t:config(priv_dir), "data", "config"]),
  filelib:ensure_dir(filename:join(Dir, "config")),
  Dir.

data_file()     -> data_file(atom_to_list(node())).
data_file(Name) -> filename:join([test_dir(), Name]).
