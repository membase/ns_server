% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_config_default).

-export([default/0, mergable/1,
         default_path/1,
         default_root_path/0,
         find_root/1, is_root/1]).

%% The only stuff that needs to be here are dynamic
%% defaults that can't be in priv/config
default() ->
    [{directory, default_path("config")},
     {nodes_wanted, [node()]}
    ] ++ default_static().

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

default_static() ->
  [ % In general, the value in these key-value pairs are property lists,
    % like [{prop_atom1, value1}, {prop_atom2, value2}].
    %
    % See the proplists erlang module.
    %
    % The special '_ver' property, by convention, is a versioning timestamp,
    % which holds the output of erlang:now().  It helps us replicate
    % configuration information out to all the nodes and helps to
    % eventually quiesce any configuration changes.
    %
    % A change to any of these rest properties probably means a restart of
    % mochiweb is needed.
    %
    % Modifiers: menelaus REST API
    % Listeners: some menelaus module that configures/reconfigures mochiweb
    {rest, [{'_ver', {0, 0, 0}},
            {port, 8080} % Port number of the REST admin API and UI.
            ]},

    % In 1.0, only the first entry in the creds list is displayed in the UI
    % and accessible through the UI.
    %
    % Modifiers: menelaus REST API
    % Listeners: some menelaus module that configures/reconfigures mochiweb??
    {rest_creds, [{'_ver', {0, 0, 0}},
                  {creds, []}
                 ]}, % An empty list means no login/password auth check.

    % Example rest_cred when a login/password is setup.
    %
    % {rest_creds, [{'_ver', {0, 0, 0}},
    %               {creds, [{"user", [{password, "password"}]},
    %                        {"admin", [{password, "admin"}]}]}
    %              ]}, % An empty list means no login/password auth check.

    % This is also a parameter to memcached ports below.
    {isasl, [{'_ver', {0, 0, 0}},
             {path, "./priv/isasl.pw"}]}, % Relative to startup directory.

    % Memcached config
    {memcached, [{'_ver', {0, 0, 0}},
            {port, 11212},
            {admin_user, "_admin"},
            {admin_pass, "_admin"},
            {buckets, ["default"]}]},

    % Moxi config
    {moxi, [{'_ver', {0, 0, 0}},
            {port, 11213}]},

    % Modifiers: menelaus (may change the 11212 port number)
    % Listeners: ns_port_sup (needs to restart its memcached processes)
    %
    % Note that we currently assume the port (11212) is available
    % across all servers in the cluster.
    %
    % This is a classic "should" key, where ns_port_sup needs
    % to try to start child processes.  If it fails, it should ns_log errors.
    {port_servers,
        [{'_ver', {0, 0, 0}},
            {memcached, "./bin/memcached/memcached",
                ["-p", "11212",
                 "-X", "./bin/memcached/stdin_term_handler.so",
                 "-E", "./bin/bucket_engine/bucket_engine.so",
                 "-e", "admin=_admin;engine=./bin/ep_engine/ep.so;default_bucket_name=default;auto_create=false"
                ],
                [{env, [{"MEMCACHED_TOP_KEYS", "100"},
                        {"ISASL_PWFILE", "./priv/isasl.pw"}, % Also isasl path above.
                        {"ISASL_DB_CHECK_TIME", "1"}
                        % TODO: Windows requires a EVENT_NOSELECT = 1 env var.
                       ]},
                    use_stdio,
                    stderr_to_stdout,
                    stream]
            },
            {moxi, "./bin/moxi/moxi",
                ["-Z", "port_listen=11213",
                 "-z", "auth=,url=http://127.0.0.1:8080/pools/default/bucketsStreaming/default,#@"
                ],
                [{env, []},
                    use_stdio,
                    stderr_to_stdout,
                    stream]
            }
        ]
    },

    % Modifiers: menelaus
    % Listeners: ? possibly ns_log
    {alerts, [{'_ver', {0, 0, 0}},
            {email, ""},
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
            ]},

    {pools, [{'_ver', {0, 0, 0}},
            {"default", [
                    {port, 11213},
                    {buckets, [
                            {"default", [
                                    {auth_plain, undefined},
                                    {size_per_node, 64} % In MB.
                                    ]}
                            %      ,
                            %      {"test_application", [
                            %        {auth_plain, {"username", "plain_text_password"}},
                            %        {size_per_node, 64} % In MB.
                            %      ]}
                            ]}
                    ]}
            ]}
  ].

