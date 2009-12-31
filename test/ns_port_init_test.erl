-compile(export_all).

% ------------------------------------------

diff_test() ->
    L1 = [
          {memcached, "./memcached",
           ["-E", "engines/default_engine.so", "-p", "11212"],
           [{env, [{"MEMCACHED_CHECK_STDIN", "thread"}]}]
          }
         ],
    L2 = [
          {memcached, "./memcached",
           ["-E", "engines/default_engine.so", "-p", "11212"],
           [{env, [{"MEMCACHED_CHECK_STDIN", "thread"}]}]
          }
         ],
    L3 = [ % Different port
          {memcached, "./memcached",
           ["-E", "engines/default_engine.so", "-p", "11313"],
           [{env, [{"MEMCACHED_CHECK_STDIN", "thread"}]}]
          }
         ],
    ?assert(L1 =:= L2),
    ?assert(L1 =/= L3),
    ?assert(L2 =/= L3),
    ?assertEqual([], lists:subtract(L1, L2)),
    ?assertEqual(L1, lists:subtract(L1, L3)),
    ?assertEqual(L3, lists:subtract(L3, L1)),
    ok.

