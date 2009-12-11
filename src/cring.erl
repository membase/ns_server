-module(cring).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

% Functional, immutable consistent-hash-ring.

-record(cring, {hash,    % A tuple of {HashMod, HashCfg}.
                ring,    % [#cpoint{}, ...], ordered by ascending point field.
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
%
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
    Points = HashMod:hash_addr(Addr, HashCfg),
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
      util:take_n(fun cpoint_not_member_by_addr/2,
                  Ring, TakeN, undefined));

search_ring_by_point([#cpoint{point = Point} | Rest] = CPoints,
                     SearchPoint, Ring, TakeN) ->
    % TODO: Do better than linear search.
    % For example, use erlang array instead of list.
    case SearchPoint =< Point of
        true  -> cpoints_addr_data(
                   util:take_n(fun cpoint_not_member_by_addr/2,
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

% Example hash_key/hash_addr functions.

hash_key(Key, _) -> misc:hash({Key, 1}).

hash_addr(Addr, NumPoints) ->
    hash_addr(Addr, 1, NumPoints, []).

hash_addr(_, _, 0, Acc) -> lists:sort(Acc);
hash_addr(Addr, Seed, N, Acc) ->
    Point = misc:hash(Addr, Seed),
    hash_addr(Addr, Point, N - 1, [Point | Acc]).

% ------------------------------------------------

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
      ?assertEqual([], C#cring.ring),
      ?assertEqual(0, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([], ?MODULE, 10),
      ?assertEqual([], C#cring.ring),
      ?assertEqual(0, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}], ?MODULE, 1),
      ?assertEqual(1, length(C#cring.ring)),
      ?assertEqual(1, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}], ?MODULE, 10),
      ?assertEqual(10, length(C#cring.ring)),
      ?assertEqual(1, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}, {b, 2}], ?MODULE, 1),
      ?assertEqual(2, length(C#cring.ring)),
      ?assertEqual(2, C#cring.addr_num),
      ok
     end)(),
    (fun () ->
      C = create([{a, 1}, {b, 2}], ?MODULE, 10),
      ?assertEqual(20, length(C#cring.ring)),
      ?assertEqual(2, C#cring.addr_num),
      ok
     end)(),
    ok.

ring_entry_test() ->
    (fun () ->
      C = create([{a, 1}, {b, 2}], ?MODULE, 1),
      ?assertEqual(2, length(C#cring.ring)),
      ?assertEqual(2, C#cring.addr_num),
      H = hd(C#cring.ring),
      [Ha] = hash_addr(a, 1),
      [Hb] = hash_addr(b, 1),
      case Ha < Hb of
        true  -> ?assertEqual(a, H#cpoint.addr);
        false -> ?assertEqual(b, H#cpoint.addr)
      end,
      ok
     end)(),
    ok.

search_test() ->
    (fun () ->
      Top = math:pow(2, 32),
      C = create([{a, 1}, {b, 2}], ?MODULE, 1),
      ?assertEqual(2, length(C#cring.ring)),
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
