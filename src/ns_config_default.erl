% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_config_default).

-export([default/0, mergable/1]).

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
    % TODO: Do something O/S specific here.
    "/tmp/data".

mergable(_CurrList) ->
    [otp,
     rest,
     rest_creds,
     port_servers,
     alerts,
     pools,
     nodes_wanted].

