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

deserialize_node_test() ->
  process_flag(trap_exit, true),
  NodeBin = <<0:8, 2:32,
    1:32, 2:32, 0:32, 0:32,
    3:32, 4:64, 5:32, 6:64, 7:32, 8:64, 0:32, 0:64, 0:32, 0:64>>,
  Node = deserialize(NodeBin, 4, 20),
  #node{m=2,children=Children,keys=Keys,offset=20} = Node,
  [{3, 4}, {5, 6}, {7, 8}] = Children,
  [1, 2] = Keys.

deserialize_leaf_test() ->
  process_flag(trap_exit, true),
  LeafBin = <<1:8, 2:32,
    1:32, 2:64, 3:32,
    4:32, 5:64, 6:32,
    0:352>>,
  Leaf = deserialize(LeafBin, 4, 20),
  #leaf{m=2,values=Values,offset=20} = Leaf,
  [{1, 2, 3}, {4, 5, 6}] = Values.

serialize_node_test() ->
  process_flag(trap_exit, true),
  Bin = serialize(#node{
    m=2,
    keys=[1, 2],
    children=[{3, 4}, {5, 6}, {7, 8}]
  }, 81),
  error_logger:info_msg("node bin ~p~n", [Bin]),
  Bin = <<0:8, 2:32,
    1:32, 2:32, 0:32, 0:32,
    3:32, 4:64, 5:32, 6:64, 7:32, 8:64, 0:192>>.

serialize_leaf_test() ->
  process_flag(trap_exit, true),
  Bin = serialize(#leaf{
    m=2,
    values=[{1, 2, 3}, {4, 5, 6}, {7, 8, 9}]
  }, 81),
  error_logger:info_msg("leaf bin ~p~n", [Bin]),
  Bin = <<1:8, 2:32,
    1:32, 2:64, 3:32,
    4:32, 5:64, 6:32,
    7:32, 8:64, 9:32,
    0:224>>.

node_round_trip_test() ->
  process_flag(trap_exit, true),
  Node = #node{
    m=2,
    keys=[1, 2],
    children=[{4, 5}, {6, 7}, {8, 9}],
    offset = 0
  },
  Node = deserialize(serialize(Node, 81), 4, 0).

leaf_round_trip_test() ->
  process_flag(trap_exit, true),
  Leaf = #leaf{
    m=2,
    values=[{1, 2, 3}, {4, 5, 6}],
    offset=0
  },
  Leaf = deserialize(serialize(Leaf, 81), 4, 0).

pointers_for_blocksize_test() ->
  process_flag(trap_exit, true),
  ?assertEqual(5, ?pointers_from_blocksize(256)),
  ?assertEqual(1, ?pointers_from_blocksize(16)).

pointer_for_size_test() ->
  process_flag(trap_exit, true),
  ?assertEqual(1, ?pointer_for_size(14, 4096)).

size_for_pointer_test() ->
  process_flag(trap_exit, true),
  ?assertEqual(16, ?size_for_pointer(1)),
  ?assertEqual(256, ?size_for_pointer(5)).

open_and_reopen_test() ->
  process_flag(trap_exit, true),
  {ok, Pid} = dmerkle_tree:start_link(data_file(), 4096),
  Root = root(Pid),
  State = state(Pid),
  dmerkle_tree:stop(Pid),
  process_flag(trap_exit, true),
  {ok, P2} = dmerkle_tree:start_link(data_file(), 4096),
  ?assertEqual(Root, root(P2)),
  S2 = state(P2),
  ?assertEqual(State#dmerkle_tree.kfpointers, S2#dmerkle_tree.kfpointers),
  dmerkle_tree:stop(Pid).

adjacent_blocks_test() ->
  process_flag(trap_exit, true),
  {ok, Pid} = dmerkle_tree:start_link(fixture("dm_adjacentblocks.idx"),
                                      4096),
  dmerkle_tree:delete_key(4741, "afknf", Pid),
  dmerkle_tree:stop(Pid).

fixture_dir() ->
  filename:join(t:config(test_dir), "fixtures").

fixture(Name) -> % need to copy the fixture for repeatability
  file:copy(filename:join(fixture_dir(), Name), data_file(Name)),
  data_file(Name).

priv_dir() ->
    Dir = filename:join([t:config(priv_dir), "data", "dmerkle_tree"]),
    filelib:ensure_dir(Dir ++ "/"),
    Dir.

data_file(Name) ->
    filename:join(priv_dir(), Name).

data_file() ->
    filename:join(priv_dir(), "dmerkle_tree").
