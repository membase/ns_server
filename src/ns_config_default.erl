% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_config_default).

-export([default/0, mergable/1,
         default_data_directory/0,
         find_root/1, is_root/1]).

default() ->
    [{directory, default_data_directory()},
     {rest, [{address, "0.0.0.0"}, % An IP binding
             {port, 8080}          % Port number of the REST admin API and UI.
            ]},
     {rest_creds, [{creds, []}]},
     {port_servers, [{memcached, "./memcached",
                      [% "-E", "engines/default_engine.so",
                       "-p", "11212"
                      ],
                      [{env, [{"MEMCACHED_CHECK_STDIN", "thread"}]}]
                     }
                    ]},
     {alerts, []},
     {pools, [{"default",
               [{address, "0.0.0.0"}, % An IP binding
                {port, 11211},
                {buckets, [{"default",
                            [{auth_plain, undefined},
                             {size_per_node, 64}, % In MB.
                             {cache_expiration_range, {0, 600}}]}
                          ]}
               ]}
             ]},
     {nodes_wanted, []}
    ].

default_data_directory() ->
    % When installed, we live in something that looks like...
    %
    %   C:/Program Files/NorthScale/Server/
    %     bin/
    %       ns_server/ebin/ns_config_default.beam
    %     priv/
    %       config
    %     data
    %
    % If we find a directory that h
    %
    P1 = filename:absname(code:which(ns_config_default)), % Our beam path.
    P2 = filename:dirname(P1), % ".../ebin"
    P3 = filename:dirname(P2), % ".../ns_server"
    P4 = filename:dirname(P3), % might be sibling to /priv
    RootPath = case find_root(P4) of
                   false -> P3;
                   X     -> X
               end,
    DataPath = filename:join(RootPath, "data"),
    filelib:ensure_dir(DataPath),
    DataPath.

find_root("") -> false;
find_root(".") -> false;
find_root("/") -> false;
find_root(DirPath) ->
    case is_root(DirPath) of
        true  -> DirPath;
        false -> find_root(filename:dirname(DirPath))
    end.

is_root(DirPath) ->
    filelib:is_dir(filename:join(DirPath, "bin")) =:= true andalso
    filelib:is_dir(filename:join(DirPath, "priv")) =:= true.

mergable(_CurrList) ->
    [otp,
     rest,
     rest_creds,
     port_servers,
     alerts,
     pools,
     nodes_wanted].

