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

increment_clock_test() ->
  Clock = create(a),
  Clock2 = increment(b, Clock),
  true = less_than(Clock, Clock2),
  Clock3 = increment(a, Clock2),
  true = less_than(Clock2, Clock3),
  Clock4 = increment(b, Clock3),
  true = less_than(Clock3, Clock4),
  Clock5 = increment(c, Clock4),
  true = less_than(Clock4, Clock5),
  Clock6 = increment(b, Clock5),
  true = less_than(Clock5, Clock6).

less_than_concurrent_test() ->
  ClockA = [{b, 1}],
  ClockB = [{a, 1}],
  false = less_than(ClockA, ClockB),
  false = less_than(ClockB, ClockA).

less_than_causal_test() ->
  ClockA = [{a,2}, {b,4}, {c,1}],
  ClockB = [{c,1}],
  true = less_than(ClockB, ClockA),
  false = less_than(ClockA, ClockB).

less_than_causal_2_test() ->
  ClockA = [{a,2}, {b,4}, {c,1}],
  ClockB = [{a,3}, {b,4}, {c,1}],
  true = less_than(ClockA, ClockB),
  false = less_than(ClockB, ClockA).

mixed_up_ordering_test() ->
  ClockA = [{b,4}, {a,2}],
  ClockB = [{a,1}, {b,3}],
  true = less_than(ClockB, ClockA),
  false = less_than(ClockA, ClockB).

equivalence_test() ->
  ClockA = [{b,4}, {a,2}],
  ClockB = [{a,2}, {b,4}],
  false = less_than(ClockA, ClockA),
  false = less_than(ClockA, ClockB),
  false = less_than(ClockB, ClockA),
  true = equals(ClockA, ClockA),
  true = equals(ClockB, ClockA),
  true = equals(ClockA, ClockB),
  false = equals(ClockA, [{a,3}, {b,3}]).

concurrent_test() ->
  ClockA = [{a,1}],
  ClockB = [{b,1}],
  true = concurrent(ClockA, ClockB).

simple_merge_test() ->
  ClockA = [{a,1}],
  ClockB = [{b,1}],
  [{a,1},{b,1}] = merge(ClockA,ClockB).

overlap_equals_merge_test() ->
  ClockA = [{a,3},{b,4}],
  ClockB = [{a,3},{c,1}],
  [{a,3},{b,4},{c,1}] = merge(ClockA, ClockB).

overlap_unequal_merge_test() ->
  ClockA = [{a,3},{b,4}],
  ClockB = [{a,4},{c,5}],
  [{a,4},{b,4},{c,5}] = merge(ClockA, ClockB).

resolve_notfound_test() ->
    ClockVals = {[{a,1}, {b, 2}], ["a", "b"]},
    ClockVals = resolve(not_found, ClockVals),
    ClockVals = resolve(ClockVals, not_found).

clock_truncation_test() ->
  Clock = [{a,1},{b,2},{c,3},{d,4},{e,5},{f,6},
           {g,7},{h,8},{i,9},{j,10},{k,11}],
  Clock1 = truncate(Clock),
  ?assertEqual(10, length(Clock1)),
  ?assertEqual(false, lists:any(fun(E) -> E =:= {a, 1} end, Clock1)).

