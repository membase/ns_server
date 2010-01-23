% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_config_default).

-export([default/0, mergable/1,
         default_path/1,
         default_root_path/0,
         find_root/1, is_root/1]).

default() ->
    [{directory, default_path("config")},
     {rest, [{'_ver', {0, 0, 0}},
             {port, 8080} % Port number of the REST admin API and UI.
            ]},
     {rest_creds, [{'_ver', {0, 0, 0}},
                   {creds, []}]},
     {isasl, [{'_ver', {0, 0, 0}},
              {path, "./isasl.pw"}]}, % Relative to priv directory.
     {bucket_admin, [{'_ver', {0, 0, 0}},
                     {user, "_admin"},
                     {pass, "_admin"}]},
     {port_servers, [{'_ver', {0, 0, 0}},
                     {memcached, "./memcached",
                      ["-E", "./engines/bucket_engine.so",
                       "-e", "admin=_admin;engine=./engines/default_engine.so;default=true;auto_create=true",
                       "-p", "11211", "-S"
                      ],
                      [{env, [{"MEMCACHED_CHECK_STDIN", "thread"},
                              {"ISASL_PWFILE", "./isasl.pw"}]}]
                     }
                    ]},
     {alerts, [{'_ver', {0, 0, 0}},
               {email, ""},
               {email_alerts, false},
               {alerts, [server_down,
                         server_up,
                         server_joined,
                         memory_low,
                         bucket_created,
                         config_changed]}
              ]},
     {pools, [{'_ver', {0, 0, 0}},
              {"default",
               [{port, 11212},
                {buckets, [{"default",
                            [{auth_plain, undefined},
                             {size_per_node, 64} % In MB.
                            ]}
                          ]}
               ]}
             ]},
     {nodes_wanted, []}
    ].

default_path(Name) ->
    RootPath = default_root_path(),
    NamePath = filename:join(RootPath, Name),
    filelib:ensure_dir(NamePath),
    NamePath.

% Returns the directory that best represents the product 'root'
% install directory.  In development, that might be the ns_server
% directory.  On windows, at install, that might be the
% C:/Program Files/NorthScale/Server.

default_root_path() ->
    % When installed, we live in something that looks like...
    %
    %   C:/Program Files/NorthScale/Server/
    %     bin/
    %       ns_server/ebin/ns_config_default.beam
    %     priv/
    %       config
    %     data
    %
    P1 = filename:absname(code:which(ns_config_default)), % Our beam path.
    P2 = filename:dirname(P1), % ".../ebin"
    P3 = filename:dirname(P2), % ".../ns_server"
    P4 = filename:dirname(P3), % might be sibling to /priv
    RootPath = case find_root(P4) of
                   false -> P3;
                   X     -> X
               end,
    RootPath.

find_root("") -> false;
find_root(".") -> false;
find_root("/") -> false;
find_root(DirPath) ->
    case is_root(DirPath) of
        true  -> DirPath;
        false -> DirNext = filename:dirname(DirPath),
                 % Case when "c:/" =:= "c:/" on windows.
                 case DirNext =/= DirPath of
                     true  -> find_root(DirNext);
                     false -> false
                 end
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
     nodes_wanted,
     test0, test1, test2].

