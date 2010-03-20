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

-module(misc_tests).
-include_lib("eunit/include/eunit.hrl").

reverse_bits_test() ->
  3869426816 = misc:reverse_bits(19088743),
  1458223569 = misc:reverse_bits(2342344554).

nthdelete_test() ->
  A = [1,2,3,4,5],
  ?assertEqual([1,2,3,4,5], misc:nthdelete(0, A)),
  ?assertEqual([1,2,3,4,5], misc:nthdelete(6, A)),
  ?assertEqual([2,3,4,5], misc:nthdelete(1, A)),
  ?assertEqual([1,2,4,5], misc:nthdelete(3, A)).

zero_split_test() ->
  ?assertEqual({<<"">>, <<0,"abcdefg">>}, misc:zero_split(<<0, "abcdefg">>)),
  ?assertEqual({<<"abd">>, <<0, "efg">>}, misc:zero_split(<<"abd", 0, "efg">>)),
  ?assertEqual({<<"abcdefg">>, <<0>>}, misc:zero_split(<<"abcdefg",0>>)),
  ?assertEqual(<<"abcdefg">>, misc:zero_split(<<"abcdefg">>)).

% hash_throughput_test_() ->
%   {timeout, 120, [{?LINE, fun() ->
%     Keys = lists:map(fun(N) ->
%         lists:duplicate(1000, random:uniform(255))
%       end, lists:seq(1,1000)),
%     FNVStart = now_float(),
%     lists:foreach(fun(Key) ->
%         fnv(Key)
%       end, Keys),
%     FNVEnd = now_float(),
%     ?debugFmt("fnv took ~ps~n", [FNVEnd - FNVStart]),
%     MStart = now_float(),
%     lists:foreach(fun(Key) ->
%         hash(Key)
%       end, Keys),
%     MEnd = now_float(),
%     ?debugFmt("murmur took ~ps~n", [MEnd - MStart]),
%     FNVNStart = now_float(),
%     lists:foreach(fun(Key) ->
%         fnv:hash(Key)
%       end, Keys),
%     FNVNEnd = now_float(),
%     ?debugFmt("fnv native took ~ps~n", [FNVNEnd - FNVNStart])
%   end}]}.
%
% fnv_native_compat_test() ->
%   ?assertEqual(fnv("blah"), fnv:hash("blah")),
%   ?assertEqual(fnv(<<"blah">>), fnv:hash(<<"blah">>)),
%   ?assertEqual(fnv([<<"blah">>, "bleg"]), fnv:hash([<<"blah">>, "bleg"])).

shuffle_test() ->
  % we can really only test that they aren't equals,
  % which won't even always work, weak
  A = [a, b, c, d, e, f, g],
  B = misc:shuffle(A),
  % ?debugFmt("shuffled: ~p", [B]),
  ?assertEqual(7, length(B)),
  ?assert(A =/= B).

rm_rf_test() ->
  lists:foldl(fun(N, Dir) ->
      NewDir = filename:join(Dir, N),
      File = filename:join(NewDir, "file"),
      filelib:ensure_dir(File),
      file:write_file(File, "blahblah"),
      NewDir
    end, priv_dir(), ["a", "b", "c", "d", "e"]),
  misc:rm_rf(filename:join(priv_dir(), "a")),
  ?assertEqual({ok, []}, file:list_dir(priv_dir())).

priv_dir() ->
  Dir = filename:join([t:config(priv_dir), "misc"]),
  filelib:ensure_dir(filename:join([Dir, "misc"])),
  Dir.

pmap_test() ->
  L = [0, 1, 2],
  ?assertEqual([0, 1],
               misc:pmap(fun(N) -> timer:sleep(N),
                                      N
                            end, L, 2)).

pmap_1_test() ->
  L = [0],
  ?assertEqual([0], misc:pmap(fun(N) -> N end, L, 1)).

