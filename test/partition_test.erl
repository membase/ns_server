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

-define(assertWithin(Lower, Upper, Expr),
  	((fun (__X,__Y) ->
  	    case (Expr) of
  		__V when __V >= __X, __V =< __Y -> ok;
  		__V -> .erlang:error({assertEqual_failed,
  				      [{module, ?MODULE},
  				       {line, ?LINE},
  				       {expression, (??Expr)},
  				       {expected, {__X,__Y}},
  				       {value, __V}]})
  	    end
  	  end)(Lower, Upper))
).

-define(assertWithinPercent(Base, Error, Expr),
  ?assertWithin(Base-(Base*Error), Base+(Base*Error), Expr)
).

node_hash_test() ->
  ?assertEqual(22, node_hash(a, [a, b, c], 64)),
  ?assertEqual(43, node_hash(b, [a, b, c], 64)),
  ?assertEqual(64, node_hash(c, [a, b, c], 64)).

rebalance_2_test_TODO() ->
  Partitions = create_partitions([{a, 64}]),
  ?debugVal(Partitions),
  Parts1 = map_partitions(Partitions, [a,b]),
  ?debugFmt("Parts1 ~p", [Parts1]),
  Sizes = sizes([a, b], Parts1),
  {value, {a, AN}} = lists:keysearch(a, 1, Sizes),
  ?assertWithinPercent(32, 0.1, AN),
  {value, {b, BN}} = lists:keysearch(b, 1, Sizes),
  ?assertWithinPercent(32, 0.1, BN),
  ?assertEqual(64, AN+BN).

monotonicity_test() ->
  Partitions = create_partitions([{a, 64}]),
  Parts1 = map_partitions(Partitions, [a,b]),
  Parts2 = map_partitions(Partitions, [a,b,c]),
  Diff = diff(Parts1, Parts2),
  ?assertEqual(false, lists:any(fun({A,B,_Part}) ->
      case {A,B} of
        {a,b} -> true;
        {b,a} -> true;
        _ -> false
      end
    end, Diff)).

monotonicity_4_test() ->
  Partitions = create_partitions([{a, 64}]),
  Parts1 = map_partitions(Partitions, [a,b,c]),
  Parts2 = map_partitions(Partitions, [a,b,c,d]),
  Diff = diff(Parts1, Parts2),
  ?assertEqual(false, lists:any(fun({A,B,_Part}) ->
      case {A,B} of
        {a,b} -> true;
        {a,c} -> true;
        {b,a} -> true;
        {b,c} -> true;
        {c,a} -> true;
        {c,b} -> true;
        _ -> false
      end
    end, Diff)).

rebalance_3_test_TODO() ->
  Partitions = create_partitions([{a, 64}]),
  Parts1 = map_partitions(Partitions, [a, b, c]),
  Sizes = sizes([a, b, c], Parts1),
  {value, {_, A}} = lists:keysearch(a, 1, Sizes),
  {value, {_, B}} = lists:keysearch(b, 1, Sizes),
  {value, {_, C}} = lists:keysearch(c, 1, Sizes),
  ?assertWithinPercent(21, 0.10, A),
  ?assertWithinPercent(21, 0.1, B),
  ?assertWithinPercent(21, 0.1, C).

minimal_rebalance_3_test_TODO() ->
  Partitions = create_partitions([{a,64}]),
  Parts1 = map_partitions(Partitions, [a,b]),
  Parts2 = map_partitions(Partitions, [a, b, c]),
  Diff = diff(Parts1, Parts2),
  ?assertWithinPercent(21, 0.10, length(Diff)).

minimal_rebalance_4_test_TODO() ->
  Partitions = create_partitions([{a,64}]),
  Parts1 = map_partitions(Partitions, [a, b, c]),
  Parts2 = map_partitions(Partitions, [a, b, c, d]),
  Diff = diff(Parts1, Parts2),
  ?assertWithinPercent(16, 0.10, length(Diff)).

create_with_4_test_TODO() ->
  Partitions = create_partitions(6, a, [a,b,c,d]),
  Sizes = sizes([a, b, c, d], Partitions),
  {value, {a, A}} = lists:keysearch(a, 1, Sizes),
  {value, {b, B}} = lists:keysearch(b, 1, Sizes),
  {value, {c, C}} = lists:keysearch(c, 1, Sizes),
  {value, {d, D}} = lists:keysearch(d, 1, Sizes),
  ?assertWithinPercent(16, 0.2, A),
  ?assertWithinPercent(16, 0.2, B),
  ?assertWithinPercent(16, 0.2, C),
  ?assertWithinPercent(16, 0.2, D).

create_partitions(Sizes) ->
  % we assume 64
  % lists:seq(1, ?power_2(32), partition_range(Q)
  {PartLists, _} = lists:foldl(
      fun ({Node, Size}, {PartLists, Count}) ->
          NewPart =
              lists:map(fun(Part) ->
                            {Node, Part-1}
                        end,
                        lists:seq(Count, Count+(Size*partition_range(6))-1,
                                  partition_range(6))),
              {PartLists ++ NewPart, Count+(Size*partition_range(6))}
      end, {[], 1}, Sizes),
  lists:keysort(2, PartLists).

hash_map_test() ->
    X = hash_map([a]),
    ?assertMatch(X, lists:keysort(1, X)),
    ok.
