-module(ns_config_default).

-export([default/0, mergable/0]).

default() ->
    [{directory, default_data_directory()},
     {http_port, 8080},
     {replica_n, 1},
     {replica_w, 1},
     {replica_r, 1},
     {auth, undefined},
     {persist, false},
     {persist_cache_expire_range, {0, 600}},
     {kinds, []},
     % TODO: Revisit these settings/configs.
     {q, 6},
     {n, 3},
     {r, 1},
     {w, 1},
     {storage_mod, storage_dets},
     {blocksize, 4096},
     {buffered_writes, undefined},
     {cache, undefined},
     {cache_size, 1048576}
    ].

default_data_directory() ->
    % TODO: Do something O/S specific here.
    "/tmp/data".

mergable() ->
    [n, r, w, q, storage_mod, blocksize, buffered_writes,
     port_servers,
     nodes_wanted,
     nodes_actual].

