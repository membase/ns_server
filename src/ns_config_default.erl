%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ns_config_default).

-export([default/0, mergable/1,
         default_path/1,
         default_root_path/0,
         find_root/1, is_root/1]).

default_path(Name) ->
    RootPath = default_root_path(),
    NamePath = filename:join(RootPath, Name),
    filelib:ensure_dir(NamePath),
    NamePath.

% Returns the directory that best represents the product 'root'
% install directory.  In development, that might be the ns_server
% directory.  On windows, at install, that might be the
% C:/Program Files/Membase/Server.
% On linux, /opt/membase/<ver>/

default_root_path() ->
    % When installed, we live in something that looks like...
    %
    %   C:/Program Files/Membase/Server/
    %     bin/
    %       ns_server/ebin/ns_config_default.beam
    %     priv/
    %       config
    %     data/ (installer created)
    %
    %   /opt/membase/<ver>/
    %     bin/
    %       ns_server/ebin/ns_config_default.beam
    %     data/ (installer created)
    %
    %   /some/dev/work/dir/ns_server/
    %     .git/
    %     bin/
    %     ebin/ns_config_default.beam
    %     priv/
    %       config
    %     data/ (dynamically created)
    %
    P1 = filename:absname(code:which(ns_config_default)), % Our beam path.
    P2 = filename:dirname(P1), % "ebin"
    P3 = filename:dirname(P2), % "ns_server" (possibly)
    RootPath = case find_root(P3) of
                   false -> filename:dirname(filename:dirname(P3));
                   X     -> X
               end,
    RootPath.

% Go up dir paths and find a development root dir.

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

% Is a development root dir?

is_root(DirPath) ->
    filelib:is_dir(filename:join(DirPath, "bin")) andalso
    filelib:is_dir(filename:join(DirPath, "priv")).

% Allow all keys to be mergable.

mergable(ListOfKVLists) ->
    sets:to_list(sets:from_list(mergable(ListOfKVLists, []))).

mergable([], Accum) ->
    Accum;
mergable([KVLists | Rest], Accum) ->
    mergable(Rest, keys(KVLists, Accum)).

keys([], Accum) -> Accum;
keys([KVList | Rest], Accum) ->
    keys(Rest, lists:map(fun({Key, _Val}) -> Key end, KVList) ++ Accum).

default() ->
    RawDbDir = filename:join(default_path("data"), misc:node_name_short()),
    DbDir = case file:read_link(RawDbDir) of
                {ok, X} -> X;
                _ -> RawDbDir
            end,
    InitQuota = case memsup:get_memory_data() of
                    {Total, _, _} -> lists:max([(Total * 4) div (1048576 * 5),
                                                (Total div 1048576) - 512]);
                    _ -> undefined
                end,
    [{directory, default_path("config")},
     {nodes_wanted, [node()]},
     {{node, node(), membership}, active},
                                                % In general, the value in these key-value pairs are property lists,
                                                % like [{prop_atom1, value1}, {prop_atom2, value2}].
                                                %
                                                % See the proplists erlang module.
                                                %
                                                % A change to any of these rest properties probably means a restart of
                                                % mochiweb is needed.
                                                %
                                                % Modifiers: menelaus REST API
                                                % Listeners: some menelaus module that configures/reconfigures mochiweb
     {rest, [{port, 8091} % Port number of the REST admin API and UI.
            ]},

                                                % In 1.0, only the first entry in the creds list is displayed in the UI
                                                % and accessible through the UI.
                                                %
                                                % Modifiers: menelaus REST API
                                                % Listeners: some menelaus module that configures/reconfigures mochiweb??
     {rest_creds, [{creds, []}
                  ]}, % An empty list means no login/password auth check.

                                                % Example rest_cred when a login/password is setup.
                                                %
                                                % {rest_creds, [{creds, [{"user", [{password, "password"}]},
                                                %                        {"admin", [{password, "admin"}]}]}
                                                %              ]}, % An empty list means no login/password auth check.

                                                % This is also a parameter to memcached ports below.
     {{node, node(), isasl}, [{path, filename:join(DbDir, "isasl.pw")}]},

                                                % Memcached config
     {{node, node(), memcached},
      [{port, 11210},
       {dbdir, DbDir},
       {admin_user, "_admin"},
       {admin_pass, "_admin"},
       {bucket_engine,
        "./bin/bucket_engine/bucket_engine.so"},
       {engines, [{membase, [{engine, "bin/ep_engine/ep.so"},
                             {initfile, "priv/init.sql"}]},
                  {memcached, [{engine, "bin/memcached/default_engine.so"}]}]},
       {verbosity, ""}]},

     {memory_quota, InitQuota},

     {buckets, [{configs, [{"default",
                            [{type, membase},
                             {num_vbuckets,
                              case (catch list_to_integer(os:getenv("VBUCKETS_NUM"))) of
                                  EnvBuckets when is_integer(EnvBuckets) -> EnvBuckets;
                                  _ -> 1024
                              end},
                             {num_replicas, 1},
                             %% default quotas will be defined when resources
                             %% stage of wizard will post data
                             {ram_quota, case is_integer(InitQuota) of
                                             true -> InitQuota * 1048576;
                                             _ -> InitQuota
                                         end},
                             {auth_type, sasl},  % none | sasl
                             {sasl_password, ""},
                             {ht_size, 3079},
                             {ht_locks, 5},
                             {servers, []},
                             {map, undefined}]
                           }]
                }]},

                                                % Moxi config
     {moxi, [{port, 11211},
             {verbosity, ""}
            ]},

                                                % Note that we currently assume the ports are available
                                                % across all servers in the cluster.
                                                %
                                                % This is a classic "should" key, where ns_port_sup needs
                                                % to try to start child processes.  If it fails, it should ns_log errors.
     {port_servers,
      [{moxi, "./bin/moxi/moxi",
        ["-Z", {"port_listen=~B,default_bucket_name=default,downstream_max=4,downstream_conn_max=8", [port]},
         "-z", {"url=http://127.0.0.1:~B/pools/default/saslBucketsStreaming",
                [{rest, port}]},
         "-p", "0",
         "-Y", "y",
         "-O", "stderr",
         {"~s", [verbosity]}
        ],
        [{env, [{"EVENT_NOSELECT", "1"},
                {"MOXI_SASL_PLAIN_USR", {"~s", [{ns_moxi_sup, rest_user, []}]}},
                {"MOXI_SASL_PLAIN_PWD", {"~s", [{ns_moxi_sup, rest_pass, []}]}}
               ]},
         use_stdio,
         stderr_to_stdout,
         stream]
       },
       {memcached, "./bin/memcached/memcached",
        ["-X", "./bin/memcached/stdin_term_handler.so",
         "-p", {"~B", [port]},
         "-E", "./bin/bucket_engine/bucket_engine.so",
         "-B", "binary",
         "-r",
         "-c", "10000",
         "-e", {"admin=~s;default_bucket_name=default;auto_create=false",
                [admin_user]},
         {"~s", [verbosity]}
        ],
        [{env, [{"EVENT_NOSELECT", "1"},
                {"MEMCACHED_TOP_KEYS", "100"},
                {"ISASL_PWFILE", {"~s", [{isasl, path}]}},
                {"ISASL_DB_CHECK_TIME", "1"}]},
         use_stdio,
         stderr_to_stdout,
         stream]
       }]
     },

     {{node, node(), ns_log}, [{filename, filename:join(DbDir, "ns_log")}]},

                                                % Modifiers: menelaus
                                                % Listeners: ? possibly ns_log
     {alerts, [{email, ""},
               {email_alerts, false},
               {email_server, [{user, undefined},
                               {pass, undefined},
                               {addr, undefined},
                               {port, undefined},
                               {encrypt, false}]},
               {alerts, [server_down,
                         server_unresponsive,
                         server_up,
                         server_joined,
                         server_left,
                         bucket_created,
                         bucket_deleted,
                         bucket_auth_failed]}
              ]}
    ].
