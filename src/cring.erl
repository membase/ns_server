% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(cring).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

% Functional, immutable consistent-hash-ring.

-record(cring, { % array(#carc{}), ordered ascending, or clockwise.
                 ring_arr,
                 % [#carc{}, ...], ordered ascending, or clockwise.
                 ring_asc,
                 % A tuple of {HashMod, HashCfg} passed to cring:create().
                 hash,
                 % length(AddrDataList) that was passed to cring:create().
                 addr_num
               }).

% A CArc is defines an arc in the consistent-hash-ring, in clockwise
% fashion, from pt_beg (exclusive) to pt_end (inclusive).
% A pt_beg may be an Integer or the atom min.
% A pt_end may be an Integer.

-record(carc, {pt_beg,   % Integer point, so (pt_beg, pt_end] is an arc.
               pt_end,   % Integer point from list from HashMod:hash_addr().
               hash_ord, % Point ordinal from list from HashMod:hash_addr().
               addr,     % Addr part of an {Addr, Data} tuple.
               data      % Data part of an {Addr, Data} tuple.
              }).

%% API

% AddrDataList is a list that looks like [{Addr, Data}*].  The Addr is
% opaque data, that for example might be an address, as long as it's
% something that HashMod understands.  The Data is opaque user data
% that the caller just wants to associate with the Addr.
%
% The HashMod module must export a hash_addr(Addr, HashCfg) function
% which returns a sorted list of Points, where Point is an int.  And,
% the HashMod module also must export a hash_key(Key, HashCfg)
% function which returns a single int or Point.

create(AddrDataList, HashMod, HashCfg) ->
    % TODO: Consider secondary sort on hash_ord to reduce (but not
    % eliminate) unlucky case when there's a hash collision.
    RingAsc = make({HashMod, HashCfg}, AddrDataList, []),
    RingArr = array:fix(array:from_list(RingAsc)),
    #cring{ring_arr = RingArr,
           ring_asc = RingAsc,
           hash = {HashMod, HashCfg},
           addr_num = length(AddrDataList)}.

% arcs(CRing) ->
%     [{addr, data, arc_here}].

% search_by_arc(CRing, BegExclusive, EndInclusive) ->
%     [{addr, data, arc_here}].

search(CRing, Key) ->
    case search(CRing, Key, 1) of
        [AddrData] -> AddrData;
        _          -> false
    end.

search(#cring{hash = {HashMod, HashCfg}} = CRing, Key, N) ->
    Point = HashMod:hash_key(Key, HashCfg),
    search_by_point(CRing, Point, N).

% Returns {Addr, Data} or false.

search_by_point(CRing, SearchPoint) ->
    case search_by_point(CRing, SearchPoint, 1) of
        [AddrData] -> AddrData;
        _          -> false
    end.

% Returns [{Addr, Data}*], where length of result might be <= N.

search_by_point(#cring{ring_arr = RingArr,
                       ring_asc = RingAsc,
                       addr_num = AddrNum},
                SearchPoint, N) ->
    TakeN = erlang:min(AddrNum, N),
    Found = case binary_arc_search(SearchPoint, RingArr) of
                false -> [];
                min -> util:take_ring_n(fun carc_not_member_by_addr/2,
                                        RingAsc, TakeN);
                max -> util:take_ring_n(fun carc_not_member_by_addr/2,
                                        RingAsc, TakeN);
                {Index, _CArc} ->
                    take_array_ring_n(fun carc_not_member_by_addr/2,
                                      RingArr, Index, TakeN)
            end,
    carcs_addr_data(Found).

%% Implementation

carcs_addr_data(CArcs) ->
    lists:map(fun (#carc{addr = Addr, data = Data}) -> {Addr, Data} end,
              CArcs).

% Returns a list of [CArc*], sorted by pt_end ascending.

make(_Hash, [], CArcs) ->
    CArcs2 = lists:keysort(#carc.pt_end, CArcs),
    {_, CArcs3} = lists:foldl(
                    fun(#carc{pt_end = Pt} = CArc, {PtPrev, Acc}) ->
                            {Pt, [CArc#carc{pt_beg = PtPrev} | Acc]}
                    end,
                    {min, []},
                    CArcs2),
    CArcs4 = lists:reverse(CArcs3),
    CArcs4;

make({HashMod, HashCfg} = Hash, [{Addr, Data} | Rest], Acc) ->
    Points = HashMod:hash_addr(Addr, HashCfg),
    {_, Acc2} =
        lists:foldl(
          fun(Point, {N, AccMore}) ->
              {N + 1, [#carc{pt_end = Point,
                             hash_ord = N,
                             addr = Addr,
                             data = Data} | AccMore]}
          end,
          {1, Acc},
          Points),
    make(Hash, Rest, Acc2).

% Returns [CArc*], where length might be <= TakeN.

search_ring_by_point([], _SearchPoint, RingAsc, TakeN) ->
    util:take_ring_n(fun carc_not_member_by_addr/2, RingAsc, TakeN);

search_ring_by_point([#carc{pt_end = Point} | Rest] = CArcsAsc,
                     SearchPoint, RingAsc, TakeN) ->
    % TODO: Do better than linear search.
    % For example, use erlang array instead of list for binary search.
    case SearchPoint =< Point of
        true  -> util:take_ring_n(fun carc_not_member_by_addr/2,
                                  CArcsAsc, TakeN, RingAsc);
        false -> search_ring_by_point(Rest, SearchPoint, RingAsc, TakeN)
    end.

carc_not_member_by_addr(#carc{addr = Addr}, CArcs) ->
    case lists:keysearch(Addr, #carc.addr, CArcs) of
        {value, _} -> false;
        false      -> true
    end.

% Example hash_key/hash_addr functions.

hash_key(Key, _) -> misc:hash({Key, 1}).

hash_addr(Addr, NumPoints) ->
    hash_addr(Addr, 1, NumPoints, []).

hash_addr(_, _, 0, Acc) -> lists:sort(Acc);
hash_addr(Addr, Seed, N, Acc) ->
    Point = misc:hash(Addr, Seed),
    hash_addr(Addr, Point, N - 1, [Point | Acc]).

% Finds a diff in CArc lists Before and After.

delta(CArcsBefore, CArcsAfter) ->
    delta(CArcsBefore, CArcsAfter, fun carc_less_than/2).

carc_less_than(X, Y) -> X#carc.pt_end < Y#carc.pt_end.

% Finds a diff in lists Before and After.

delta(Before, After, LessThenFunc) ->
    B1 = Before ++ [max],
    A1 = After ++ [max],
    G = delta(min, B1, min, A1, {Before, After, LessThenFunc}, []),
    case G of
        [{Node, {min, _NodePoint}, FromNode} | _] ->
            Last = case Before of
                       [] -> undefined;
                       _  -> lists:last(Before)
                   end,
            [{Node, {Last, max}, FromNode} | G];
        _ -> G
    end.

delta_done(Grows) -> lists:reverse(Grows).

delta(_, [], _, _, _, Grows) -> delta_done(Grows);
delta(_, _, _, [], _, Grows) -> delta_done(Grows);

delta(_BPrev, [X | BRest],
      _APrev, [X | ARest],
      BAFull, Grows) ->
    delta(X, BRest, X, ARest, BAFull, Grows);

delta(BPrev, [B | BRest] = BList,
      APrev, [A | ARest] = AList,
      {Before, After, LessThenFunc} = BAFull, Grows) ->
    if B =:= max -> delta(BPrev, BList,
                          A, ARest,
                          BAFull,
                          [{A, {APrev, A}, delta_next(BList,
                                                      Before)} | Grows]);
       A =:= max -> delta(B, BRest,
                          APrev, AList,
                          BAFull,
                          [{delta_next(AList, After),
                            {BPrev, B},
                            delta_next(BList, Before)} | Grows]);
       true ->
            BLessThenA = LessThenFunc(B, A),
            case BLessThenA of
                true  -> delta(B, BRest,
                               APrev, AList,
                               BAFull,
                               [{A, {BPrev, B}, B} | Grows]);
                false -> delta(BPrev, BList,
                               A, ARest,
                               BAFull,
                               [{A, {APrev, A}, delta_next(BList,
                                                           Before)} | Grows])
            end
    end.

delta_next(_, [])          -> undefined;
delta_next([max], Restart) -> delta_next(Restart, undefined);
delta_next([A | _], _)     -> A;
delta_next([], Restart)    -> delta_next(Restart, undefined).

% ------------------------------------------------

%% Lo and Hi inclusively bound the portion of Arr to be searched for
%% the arc that owns the point K.  Or, returns undefined if beyond
%% the array entries.

binary_arc_search(K, Arr) ->
    S = array:size(Arr),
    case S > 0 of
        true  -> binary_arc_search(K, Arr, 0, S - 1);
        false -> false
    end.

binary_arc_search(K, Arr, Lo, Hi) ->
    case Lo =< Hi of
        true ->
            Probe = (Lo + Hi) div 2,
            CArc = array:get(Probe, Arr),
            #carc{pt_beg = PtBeg, pt_end = PtEnd} = CArc,
            if
                PtEnd < K ->
                    binary_arc_search(K, Arr, Probe + 1, Hi);
                PtBeg =:= min ->
                    min;
                K =< PtBeg ->
                    binary_arc_search(K, Arr, Lo, Probe - 1);
                true -> % When K within (PtBeg, PtEnd].
                    {Probe, CArc}
            end;
        _ ->
            case Hi < 0 of
                true  -> min;
                false -> max
            end
    end.

% ------------------------------------------------

take_array_ring_n(AcceptFun, RingArr, Index, N) ->
    take_array_ring_n(AcceptFun, RingArr, Index, N, []).

take_array_ring_n(_AcceptFun, _RingArr, _Index, 0, Taken) ->
    lists:reverse(Taken);

take_array_ring_n(AcceptFun, RingArr, Index, N, Taken) ->
    RingSize = array:size(RingArr),
    case (Index >= RingSize andalso RingSize > 0) of
        true ->
            take_array_ring_n(AcceptFun, RingArr, 0, N, Taken);
        false ->
            X = array:get(Index, RingArr),
            case AcceptFun(X, Taken) of
                true  -> take_array_ring_n(AcceptFun, RingArr,
                                           Index + 1, N - 1, [X | Taken]);
                false -> take_array_ring_n(AcceptFun, RingArr,
                                           Index + 1, N - 1, Taken)
            end
    end.

% ------------------------------------------------

binary_arc_test() ->
    X = #carc{pt_beg = min,
              pt_end = 10,
              addr = x},
    Y = #carc{pt_beg = 10,
              pt_end = 20,
              addr = y},
    A = array:from_list([]),
    ?assertEqual(false, binary_arc_search(0, A)),
    ?assertEqual(false, binary_arc_search(1, A)),
    ?assertEqual(false, binary_arc_search(10, A)),
    A2 = array:from_list([X]),
    ?assertEqual(min, binary_arc_search(0, A2)),
    ?assertEqual(min, binary_arc_search(1, A2)),
    ?assertEqual(min, binary_arc_search(10, A2)),
    ?assertEqual(max, binary_arc_search(11, A2)),
    A3 = array:from_list([X,Y]),
    ?assertEqual(min, binary_arc_search(0, A3)),
    ?assertEqual(min, binary_arc_search(1, A3)),
    ?assertEqual(min, binary_arc_search(10, A3)),
    ?assertMatch({1, Y}, binary_arc_search(11, A3)),
    ?assertMatch({1, Y}, binary_arc_search(20, A3)),
    ?assertEqual(max, binary_arc_search(21, A3)),
    ok.

hash_addr_test() ->
    P = hash_addr(a, 1),
    ?assertEqual(1, length(P)),
    P2 = hash_addr(a, 2),
    ?assertEqual(2, length(P2)),
    P8 = hash_addr(a, 8),
    ?assertEqual(8, length(P8)),
    P160 = hash_addr(a, 160),
    ?assertEqual(160, length(P160)),
    ok.

create_test() ->
    (fun () ->
      C = create([], ?MODULE, 1),
      ?assertEqual([], C#cring.ring_asc),
      ?assertEqual(0, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([], ?MODULE, 10),
      ?assertEqual([], C#cring.ring_asc),
      ?assertEqual(0, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}], ?MODULE, 1),
      ?assertEqual(1, length(C#cring.ring_asc)),
      ?assertEqual(1, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}], ?MODULE, 10),
      ?assertEqual(10, length(C#cring.ring_asc)),
      ?assertEqual(1, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}, {b, 2}], ?MODULE, 1),
      ?assertEqual(2, length(C#cring.ring_asc)),
      ?assertEqual(2, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}, {b, 2}], ?MODULE, 10),
      ?assertEqual(20, length(C#cring.ring_asc)),
      ?assertEqual(2, C#cring.addr_num),
      ok
     end)(),
    ok.

ring_entry_test() ->
    (fun () ->
      C = create([{a, 1}, {b, 2}], ?MODULE, 1),
      ?assertEqual(2, length(C#cring.ring_asc)),
      ?assertEqual(2, C#cring.addr_num),
      H = hd(C#cring.ring_asc),
      [Ha] = hash_addr(a, 1),
      [Hb] = hash_addr(b, 1),
      case Ha < Hb of
        true  -> ?assertEqual(a, H#carc.addr);
        false -> ?assertEqual(b, H#carc.addr)
      end,
      ok
     end)(),
    ok.

search_test() ->
    (fun () ->
      Top = math:pow(2, 32),
      C = create([{a, 1}, {b, 2}], ?MODULE, 1),
      ?assertEqual(2, length(C#cring.ring_asc)),
      ?assertEqual(2, C#cring.addr_num),
      X = search_by_point(C, 0),
      Y = search_by_point(C, Top),
      [Ha] = hash_addr(a, 1),
      [Hb] = hash_addr(b, 1),
      case Ha < Hb of
        true  -> ?assertEqual({a, 1}, X),
                 ?assertEqual({a, 1}, Y);
        false -> ?assertEqual({b, 2}, X),
                 ?assertEqual({b, 2}, Y)
      end,
      Z = search_by_point(C, hash_key(a, undefined) + 1),
      ?assertEqual({b, 2}, Z),
      W = search_by_point(C, hash_key(b, undefined) + 1),
      ?assertEqual({a, 1}, W),
      Z1 = search_by_point(C, hash_key(a, undefined) - 1),
      ?assertEqual({a, 1}, Z1),
      W1 = search_by_point(C, hash_key(b, undefined) - 1),
      ?assertEqual({b, 2}, W1),
      Z2 = search_by_point(C, hash_key(a, undefined)),
      ?assertEqual({a, 1}, Z2),
      W2 = search_by_point(C, hash_key(b, undefined)),
      ?assertEqual({b, 2}, W2),
      ok
     end)(),
    ok.

delta_grow_test() ->
    delta_check(
      [],
      [15],
      [{15, {undefined, max}, undefined},
       {15, {min, 15}, undefined}]),
    delta_check(
      [],
      [15, 25],
      [{15, {undefined, max}, undefined},
       {15, {min, 15}, undefined},
       {25, {15, 25}, undefined}]),
    delta_check(
      [10, 20],
      [10, 15, 20],
      [{15, {10, 15}, 20}]),
    delta_check(
      [10, 20],
      [10, 15, 17, 20],
      [{15, {10, 15}, 20},
       {17, {15, 17}, 20}]),
    delta_check(
      [10],
      [5, 10],
      [{5, {10, max}, 10},
       {5, {min, 5}, 10}]),
    delta_check(
      [10, 20],
      [5, 10, 20],
      [{5, {20, max}, 10},
       {5, {min, 5}, 10}]),
    delta_check(
      [10],
      [10, 15],
      [{15, {10, 15}, 10}]),
    delta_check(
      [10, 20, 30],
      [10, 15, 20, 25, 30],
      [{15, {10, 15}, 20},
       {25, {20, 25}, 30}]),
    delta_check(
      [10, 20, 30],
      [10, 15, 20, 25, 30, 35],
      [{15, {10, 15}, 20},
       {25, {20, 25}, 30},
       {35, {30, 35}, 10}]),
    ok.

delta_shrink_test() ->
    delta_check(
      [15],
      [],
      [{undefined, {15, max}, 15},
       {undefined, {min, 15}, 15}]),
    delta_check(
      [15, 25],
      [],
      [{undefined, {25, max}, 15},
       {undefined, {min, 15}, 15},
       {undefined, {15, 25}, 25}]),
    delta_check(
      [10, 15, 20],
      [10, 20],
      [{20, {10, 15}, 15}]),
    delta_check(
      [10, 15, 17, 20],
      [10, 20],
      [{20, {10, 15}, 15},
       {20, {15, 17}, 17}]),
    delta_check(
      [5, 10],
      [10],
      [{10, {10, max}, 5},
       {10, {min, 5}, 5}]),
    delta_check(
      [5, 10, 20],
      [10, 20],
      [{10, {20, max}, 5},
       {10, {min, 5}, 5}]),
    delta_check(
      [5, 10, 25],
      [10],
      [{10, {25, max}, 5},
       {10, {min, 5}, 5},
       {10, {10, 25}, 25}]),
    delta_check(
      [10, 15],
      [10],
      [{10, {10, 15}, 15}]),
    delta_check(
      [10, 15, 20, 25, 30],
      [10, 20, 30],
      [{20, {10, 15}, 15},
       {30, {20, 25}, 25}]),
    delta_check(
      [10, 15, 20, 25, 30, 35],
      [10, 20, 30],
      [{20, {10, 15}, 15},
       {30, {20, 25}, 25},
       {10, {30, 35}, 35}]),
    ok.

delta_grow_shrink_test() ->
    delta_check(
      [10, 20, 25, 30, 35],
      [10, 15, 20, 30],
      [{15, {10, 15}, 20},
       {30, {20, 25}, 25},
       {10, {30, 35}, 35}]),
    delta_check(
      [10, 15, 20, 30, 35],
      [10, 20, 25, 30],
      [{20, {10, 15}, 15},
       {25, {20, 25}, 30},
       {10, {30, 35}, 35}]),
    delta_check(
      [10, 15, 30],
      [10, 25, 30],
      [{25, {10, 15}, 15},
       {25, {10, 25}, 30}]),
    delta_check(
      [10, 15],
      [10, 25],
      [{25, {10, 15}, 15},
       {25, {10, 25}, 10}]),
    delta_check(
      [15],
      [25],
      [{25, {15, max}, 15},
       {25, {min, 15}, 15},
       {25, {min, 25}, 15}]),
    ok.

delta_grow_replicas_test() ->
    ok.

delta_check(Before, After, ExpectGrows) ->
    LessThenFunc = fun (X, Y) -> X < Y end,
    Grows = delta(Before, After, LessThenFunc),
%   ?debugVal(Before),
%   ?debugVal(After),
%   ?debugVal(ExpectGrows),
%   ?debugVal(Grows),
    ?assertEqual(ExpectGrows, Grows),
    ok.

