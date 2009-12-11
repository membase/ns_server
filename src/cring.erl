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
% which returns [Points*], where Point is an int.  And, the HashMod
% module also must export a hash_key(Key, HashCfg) function which
% returns a single int or Point.

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
    take_n(Ring, TakeN, undefined);

search_ring_by_point([#cpoint{point = Point} | Rest] = CPoints,
                     SearchPoint, Ring, TakeN) ->
    % TODO: Do better than linear search.
    case SearchPoint =< Point of
        true  -> take_n(CPoints, TakeN, Ring);
        false -> search_ring_by_point(Rest, SearchPoint, Ring, TakeN)
    end.

take_n(CPoints, N, Restart) ->
    Taken = take_n(CPoints, N, Restart, []),
    lists:map(fun (#cpoint{addr = Addr, data = Data}) ->
                      {Addr, Data}
              end,
              Taken).

take_n([], _, undefined, Taken) -> lists:reverse(Taken);
take_n([], N, Restart, Taken)   -> take_n(Restart, N, undefined, Taken);
take_n([#cpoint{addr = Addr} = CPoint, Rest], N, Restart, Taken) ->
    case lists:keysearch(Addr, #cpoint.addr, Taken) of
        {value, _} ->
            take_n(Rest, N, Restart, Taken);
        false ->
            take_n(Rest, N - 1, Restart, [CPoint | Taken])
    end.

% Example hash_key/hash_addr functions.

hash_key(Key, _) -> misc:hash(Key).

hash_addr(Addr, NumPoints) ->
    hash_addr(Addr, 1, NumPoints, []).

hash_addr(_, _, 0, Acc)         -> lists:reverse(Acc);
hash_addr(_, _, undefined, Acc) -> lists:reverse(Acc);
hash_addr(Addr, Seed, N, Acc) ->
    Point = misc:hash(Addr, Seed),
    hash_addr(Addr, Point, N - 1, [Point | Acc]).
