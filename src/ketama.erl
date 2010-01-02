-module(ketama).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

% IsWeighted
% PointsPerServer = POINTS_PER_SERVER = 100 % the default
% PointsPerServer = POINTS_PER_SERVER_KETAMA = 160 % when weighted

hash_addr(Addr, undefined) ->
    hash_addr(Addr, 160);

hash_addr({Host, Port} = _Addr, NumPoints) ->
    BinHost = bin(Host),
    BinPort = bin(integer_to_list(Port)),
    BinPrefix = <<BinHost/binary, $:, BinPort/binary, $->>,
    hash_addr(BinPrefix, 0, NumPoints / 4, []).

hash_addr(_, Iter, Until, Points) when Iter >= Until ->
    lists:usort(Points);

hash_addr(BinPrefix, Iter, Until, Points) ->
    BinIter = bin(integer_to_list(Iter)),
    BinInput = <<BinPrefix/binary, BinIter/binary>>,
    BinDigest = erlang:md5(BinInput),
    <<H0:8, H1:8, H2:8, H3:8,
      I0:8, I1:8, I2:8, I3:8,
      J0:8, J1:8, J2:8, J3:8,
      K0:8, K1:8, K2:8, K3:8>> = BinDigest,
    BinPoints = <<H3:8, H2:8, H1:8, H0:8,
                  I3:8, I2:8, I1:8, I0:8,
                  J3:8, J2:8, J1:8, J0:8,
                  K3:8, K2:8, K1:8, K0:8>>,
    <<B1:32, B2:32, B3:32, B4:32>> = BinPoints,
    hash_addr(BinPrefix, Iter + 1, Until, [B1, B2, B3, B4 | Points]).

hash_key(Key, _HashCfg) ->
    BinKey = bin(Key),
    Digest = erlang:md5(BinKey),
    <<H0:8, H1:8, H2:8, H3:8, _:96>> = Digest,
    BinPoint = <<H3:8, H2:8, H1:8, H0:8>>,
    <<Point:32>> = BinPoint,
    Point.

bin(undefined)         -> <<>>;
bin(L) when is_list(L) -> iolist_to_binary(L);
bin(X)                 -> <<X/binary>>.

% -------------------------------------------------

assertHash(Str, HashExpect) ->
    HashActual = hash_key(Str, undefined),
    ?assertEqual(HashExpect, HashActual),
    ok.

% These values came from libketama's test prog, via spymemcached.

hash_key_test() ->
    assertHash("26", 3979113294),
    assertHash("1404", 2065000984),
    assertHash("4177", 1125759251),
    assertHash("9315", 3302915307),
    assertHash("14745", 2580083742),
    assertHash("105106", 3986458246),
    assertHash("355107", 3611074310),
    ok.

hash_addr_test() ->
    Points = hash_addr({"host", 11211}, 160),
    ?assertEqual(lists:usort(Points), Points),
    P = hash_key("host:11211-0", undefined),
    ?assert(lists:member(P, Points)),
    ok.

some_test_addrs(N) ->
    Addrs = lists:map(fun(X) -> {{"127.0.0.1", 10000 + X}, some_data} end,
                      lists:seq(0, N - 1)),
    R = cring:create(Addrs, ?MODULE, 160),
    AssertSame =
        fun(ExpectAddrIndex, Key) ->
            ExpectAddr = lists:nth(ExpectAddrIndex, Addrs),
            ActualAddr = cring:search_by_point(R, hash_key(Key, undefined)),
            ?assertEqual(ExpectAddr, ActualAddr),
            ok
        end,
    {Addrs, R, AssertSame}.

ketama_cring_test() ->
    {_Addrs, _R, AssertSame} = some_test_addrs(4),
    % Data from spymemcached KetamaNodeLocatorTest.java.
    AssertSame(1, "dustin"),
    AssertSame(3, "noelani"),
    AssertSame(1, "some other key"),
    ok.

continuum_wrapping_test() ->
    {_Addrs, _R, AssertSame} = some_test_addrs(4),
    % Data from spymemcached KetamaNodeLocatorTest.java.
    AssertSame(4, "V5XS8C8N"),
    AssertSame(4, "8KR2DKR2"),
    AssertSame(4, "L9KH6X4X"),
    ok.

cluster_resizing_test() ->
    % Data from spymemcached KetamaNodeLocatorTest.java.
    (fun() ->
      {_Addrs, _R, AssertSame} = some_test_addrs(4),
      AssertSame(1, "dustin"),
      AssertSame(3, "noelani"),
      AssertSame(1, "some other key"),
      ok
     end)(),
    (fun() ->
      {_Addrs, _R, AssertSame} = some_test_addrs(5),
      AssertSame(1, "dustin"),
      AssertSame(3, "noelani"),
      AssertSame(5, "some other key"),
      ok
     end)(),
    ok.

