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

-module(vclock).

-export([create/1, truncate/1, increment/2, compare/2, resolve/2, merge/2]).

-include_lib("eunit/include/eunit.hrl").

-ifdef(TEST).
-include("test/vclock_test.erl").
-endif.

create(NodeName) -> [{NodeName, misc:now_float()}].

truncate(Clock) when length(Clock) > 10 ->
  lists:nthtail(length(Clock) - 10, lists:keysort(2, Clock));

truncate(Clock) -> Clock.

increment(NodeName, [{NodeName, _Version}|Clocks]) ->
	[{NodeName, misc:now_float()}|Clocks];

increment(NodeName, [NodeClock|Clocks]) ->
	[NodeClock|increment(NodeName, Clocks)];

increment(NodeName, []) ->
	[{NodeName, misc:now_float()}].

resolve({ClockA, ValuesA}, {ClockB, ValuesB}) ->
  case compare(ClockA, ClockB) of
    less -> {ClockB, ValuesB};
    greater -> {ClockA, ValuesA};
    equal -> {ClockA, ValuesA};
    concurrent -> {merge(ClockA,ClockB), ValuesA ++ ValuesB}
  end;
resolve(not_found, {Clock, Values}) -> {Clock, Values};
resolve({Clock, Values}, not_found) -> {Clock, Values};
resolve(not_found, not_found)       -> not_found.

merge(ClockA, ClockB)     -> merge([], ClockA, ClockB).
merge(Merged, [], ClockB) -> lists:keysort(1, Merged ++ ClockB);
merge(Merged, ClockA, []) -> lists:keysort(1, Merged ++ ClockA);

merge(Merged, [{NodeA, VersionA}|ClockA], ClockB) ->
  case lists:keytake(NodeA, 1, ClockB) of
    {value, {NodeA, VersionB}, TrunkClockB} when VersionA > VersionB ->
      merge([{NodeA,VersionA}|Merged],ClockA,TrunkClockB);
    {value, {NodeA, VersionB}, TrunkClockB} ->
      merge([{NodeA,VersionB}|Merged],ClockA,TrunkClockB);
    false ->
      merge([{NodeA,VersionA}|Merged],ClockA,ClockB)
  end.

compare(ClockA, ClockB) ->
  AltB = less_than(ClockA, ClockB),
  BltA = less_than(ClockB, ClockA),
  AeqB = equals(ClockA, ClockB),
  AccB = concurrent(ClockA, ClockB),
  if
    AltB -> less;
    BltA -> greater;
    AeqB -> equal;
    AccB -> concurrent
  end.

% ClockA is less than ClockB if and only if ClockA[z] <= ClockB[z]
% for all instances z and there exists an index z'
% such that ClockA[z'] < ClockB[z']
less_than(ClockA, ClockB) ->
  ForAll = lists:all(fun({Node, VersionA}) ->
    case lists:keysearch(Node, 1, ClockB) of
      {value, {_NodeB, VersionB}} -> VersionA =< VersionB;
      false -> false
    end
  end, ClockA),
  Exists = lists:any(fun({NodeA, VersionA}) ->
    case lists:keysearch(NodeA, 1, ClockB) of
      {value, {_NodeB, VersionB}} -> VersionA /= VersionB;
      false -> true
    end
  end, ClockA),
  % length takes care of the case when clockA is shorter than B
  ForAll and (Exists or (length(ClockA) < length(ClockB))).

equals(ClockA, ClockB) ->
  Equivalent = lists:all(fun({NodeA, VersionA}) ->
    lists:any(fun(NodeClockB) ->
      case NodeClockB of
        {NodeA, VersionA} -> true;
        _ -> false
      end
    end, ClockB)
  end, ClockA),
  Equivalent and (length(ClockA) == length(ClockB)).

concurrent(ClockA, ClockB) ->
  not (less_than(ClockA, ClockB) or
       less_than(ClockB, ClockA) or
       equals(ClockA, ClockB)).
