-module(cring).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

% Functional, immutable consistent-hash-ring.

-record(cring, {hash,    % A tuple of {HashMod, HashCfg}.
                ring,    % A list of cpoint records, ordered by point field.
                addr_num % length(AddrDataList).
               }).
-record(cpoint, {point,     % Integer, an item from list from HashMod:hash_addr().
                 point_ord, % Position ordinal from list from HashMod:hash_addr().
                 addr,      % Addr part of an {Addr, Data} tuple.
                 data}).    % Data part of an {Addr, Data} tuple.

%% API

% AddrDataList is a list that looks like [{Addr, Data}*].  The Addr is
% opaque data, that for example might be an address, as long as it's
% something that HashMod understands.  The Data is opaque user data
% that the caller just wants to associate with the Addr.

create(AddrDataList) ->
    create(AddrDataList, ?MODULE, undefined).

% The HashMod module must export a hash_addr(Addr, HashCfg) function
% which returns a sorted list of Points, where Point is an int.  And,
% the HashMod module also must export a hash_key(Key, HashCfg)
% function which returns a single int or Point.

create(AddrDataList, HashMod, HashCfg) ->
    Ring = make({HashMod, HashCfg}, AddrDataList, []),
    #cring{hash = {HashMod, HashCfg},
           ring = Ring,
           addr_num = length(AddrDataList)}.

% Returns {Addr, Data} or false.

search_by_point(CRing, SearchPoint) ->
    case search_by_point(CRing, SearchPoint, 1) of
        [AddrData] -> AddrData;
        _          -> false
    end.

% Returns [{Addr, Data}*], where length of result might be <= N.

search_by_point(#cring{ring = Ring, addr_num = AddrNum}, SearchPoint, N) ->
    search_ring_by_point(Ring, SearchPoint, Ring, erlang:min(AddrNum, N)).

%% Implementation

make(_Hash, [], CPoints) ->
    % TODO: Consider secondary sort on point_ord to reduce (but not
    % eliminate) unlucky case when there's a hash collision.
    lists:keysort(#cpoint.point, CPoints);

make({HashMod, HashCfg} = Hash, [{Addr, Data} | Rest], Acc) ->
    {ok, Points} = HashMod:hash_addr(Addr, HashCfg),
    {_, Acc2} =
        lists:foldl(
          fun (Point, {N, AccMore}) ->
              {N + 1, [#cpoint{point = Point,
                               point_ord = N,
                               addr = Addr,
                               data = Data} | AccMore]}
          end,
          {1, Acc},
          Points),
    make(Hash, Rest, Acc2).

search_ring_by_point([], _SearchPoint, Ring, TakeN) ->
    cpoints_addr_data(
      take_n(fun cpoint_not_member_by_addr/2,
             Ring, TakeN, undefined));

search_ring_by_point([#cpoint{point = Point} | Rest] = CPoints,
                     SearchPoint, Ring, TakeN) ->
    % TODO: Do better than linear search.
    case SearchPoint =< Point of
        true  -> cpoints_addr_data(
                   take_n(fun cpoint_not_member_by_addr/2,
                          CPoints, TakeN, Ring));
        false -> search_ring_by_point(Rest, SearchPoint, Ring, TakeN)
    end.

cpoint_not_member_by_addr(#cpoint{addr = Addr}, CPoints) ->
    case lists:keysearch(Addr, #cpoint.addr, CPoints) of
        {value, _} -> false;
        false      -> true
    end.

cpoints_addr_data(CPoints) ->
    lists:map(fun (#cpoint{addr = Addr, data = Data}) -> {Addr, Data} end,
              CPoints).

take_n(AcceptFun, CPoints, N, Restart) ->
    take_n(AcceptFun, CPoints, N, Restart, []).

take_n(_AcceptFun, _, 0, _Restart, Taken)   -> lists:reverse(Taken);
take_n(_AcceptFun, [], _, undefined, Taken) -> lists:reverse(Taken);
take_n(AcceptFun, [], N, Restart, Taken)    -> take_n(AcceptFun, Restart, N,
                                                      undefined, Taken);
take_n(AcceptFun, [CPoint | Rest], N, Restart, Taken) ->
    case AcceptFun(CPoint, Taken) of
        true  -> take_n(AcceptFun, Rest, N - 1, Restart, [CPoint | Taken]);
        false -> take_n(AcceptFun, Rest, N, Restart, Taken)
    end.

% Example hash_key/hash_addr functions.

hash_key(Key, _) -> misc:hash(Key).

hash_addr(Addr, NumPoints) ->
    hash_addr(Addr, 1, NumPoints, []).

hash_addr(_, _, 0, Acc)         -> lists:sort(Acc);
hash_addr(_, _, undefined, Acc) -> lists:sort(Acc);
hash_addr(Addr, Seed, N, Acc) ->
    Point = misc:hash(Addr, Seed),
    hash_addr(Addr, Point, N - 1, [Point | Acc]).

% ------------------------------------------------

ident(X)            -> X.
not_member(X, List) -> not lists:member(X, List).

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

take_n_test() ->
    E = take_n(fun not_member/2, [], 0, []),
    ?assertEqual([], E),
    E1 = take_n(fun not_member/2, [], 5, []),
    ?assertEqual([], E1),
    E2 = take_n(fun not_member/2, [1, 2, 3], 0, []),
    ?assertEqual([], E2),
    E3 = take_n(fun not_member/2, [1, 2, 3], 0, [10, 11, 12]),
    ?assertEqual([], E3),
    XE = take_n(fun not_member/2, [1], 1, [10]),
    ?assertEqual([1], XE),
    XE1 = take_n(fun not_member/2, [1], 5, [10]),
    ?assertEqual([1, 10], XE1),
    XE2 = take_n(fun not_member/2, [1, 2, 3], 5, [10, 11, 12]),
    ?assertEqual([1, 2, 3, 10, 11], XE2),
    XE3 = take_n(fun not_member/2, [1, 2, 3], 6, [10, 11, 12]),
    ?assertEqual([1, 2, 3, 10, 11, 12], XE3),
    XE4 = take_n(fun not_member/2, [1, 2, 3], 10, [10, 11, 12]),
    ?assertEqual([1, 2, 3, 10, 11, 12], XE4),
    ok.

take_n_duplicates_test() ->
    XE = take_n(fun not_member/2, [1], 1, [1]),
    ?assertEqual([1], XE),
    XE1 = take_n(fun not_member/2, [1], 5, [1]),
    ?assertEqual([1], XE1),
    XE2 = take_n(fun not_member/2, [1, 2, 3], 5, [3, 2, 1]),
    ?assertEqual([1, 2, 3], XE2),
    XE3 = take_n(fun not_member/2, [1, 2, 3], 6, [1, 1, 2]),
    ?assertEqual([1, 2, 3], XE3),
    XE4 = take_n(fun not_member/2, [1, 2, 3], 10, [1, 2, 3]),
    ?assertEqual([1, 2, 3], XE4),
    XE5 = take_n(fun not_member/2, [1, 1, 1], 10, [1, 1, 1]),
    ?assertEqual([1], XE5),
    ok.
