% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(util).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

identity(X) -> X.
true(_)     -> true.
false(_)    -> false.

not_member(X, List) -> not lists:member(X, List).

% Takes N elements from a RingList, which is a List but
% is considered to "wrap around".

take_ring_n(RingList, N) ->
    take_ring_n(fun true/1, RingList, N).

take_ring_n(AcceptFun, RingList, N) ->
    take_ring_n(AcceptFun, RingList, N, RingList).

take_ring_n(AcceptFun, RingList, N, Restart) ->
    take_ring_n(AcceptFun, RingList, N, Restart, []).

take_ring_n(_AcceptFun, _, 0, _Restart, Taken)   -> lists:reverse(Taken);
take_ring_n(_AcceptFun, [], _, undefined, Taken) -> lists:reverse(Taken);

take_ring_n(AcceptFun, [], N, Restart, Taken) ->
    take_ring_n(AcceptFun, Restart, N, undefined, Taken);

take_ring_n(AcceptFun, [Item | Rest], N, Restart, Taken) ->
    case AcceptFun(Item, Taken) of
        true  -> take_ring_n(AcceptFun, Rest, N - 1, Restart, [Item | Taken]);
        false -> take_ring_n(AcceptFun, Rest, N, Restart, Taken)
    end.

% ------------------------------------------

take_ring_n_test() ->
    E = take_ring_n(fun not_member/2, [], 0, []),
    ?assertEqual([], E),
    E1 = take_ring_n(fun not_member/2, [], 5, []),
    ?assertEqual([], E1),
    E2 = take_ring_n(fun not_member/2, [1, 2, 3], 0, []),
    ?assertEqual([], E2),
    E3 = take_ring_n(fun not_member/2, [1, 2, 3], 0, [10, 11, 12]),
    ?assertEqual([], E3),
    XE = take_ring_n(fun not_member/2, [1], 1, [10]),
    ?assertEqual([1], XE),
    XE1 = take_ring_n(fun not_member/2, [1], 5, [10]),
    ?assertEqual([1, 10], XE1),
    XE2 = take_ring_n(fun not_member/2, [1, 2, 3], 5, [10, 11, 12]),
    ?assertEqual([1, 2, 3, 10, 11], XE2),
    XE3 = take_ring_n(fun not_member/2, [1, 2, 3], 6, [10, 11, 12]),
    ?assertEqual([1, 2, 3, 10, 11, 12], XE3),
    XE4 = take_ring_n(fun not_member/2, [1, 2, 3], 10, [10, 11, 12]),
    ?assertEqual([1, 2, 3, 10, 11, 12], XE4),
    ok.

take_ring_n_duplicates_test() ->
    XE = take_ring_n(fun not_member/2, [1], 1, [1]),
    ?assertEqual([1], XE),
    XE1 = take_ring_n(fun not_member/2, [1], 5, [1]),
    ?assertEqual([1], XE1),
    XE2 = take_ring_n(fun not_member/2, [1, 2, 3], 5, [3, 2, 1]),
    ?assertEqual([1, 2, 3], XE2),
    XE3 = take_ring_n(fun not_member/2, [1, 2, 3], 6, [1, 1, 2]),
    ?assertEqual([1, 2, 3], XE3),
    XE4 = take_ring_n(fun not_member/2, [1, 2, 3], 10, [1, 2, 3]),
    ?assertEqual([1, 2, 3], XE4),
    XE5 = take_ring_n(fun not_member/2, [1, 1, 1], 10, [1, 1, 1]),
    ?assertEqual([1], XE5),
    ok.

