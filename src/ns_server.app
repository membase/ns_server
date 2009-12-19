{application, ns_server,
 [{description, "The NorthScale smart server."},
  {vsn, "1.0"},
  {modules, [ns_config,
             ns_config_default,
             ns_config_log,
             ns_config_sup,
             ns_server,
             ns_server_sup
            ]},
  {registered, [ns_server_sup,
                ns_config,
                ns_config_sup,
                ns_config_events]},
  {applications, [kernel, stdlib]},
  {mod, {ns_server, []}},

  % To  prevent  a  supervisor  from getting into an infinite loop of child
  % process terminations and  restarts,  a  maximum  restart  frequency  is
  % defined  using  two  integer  values  MaxR  and MaxT. If more than MaxR
  % restarts occur within MaxT seconds, the supervisor terminates all child
  % processes and then itself.

  {env, [{max_r, 3},
         {max_t, 10},
         {ns_server_config, "priv/config"}]}
 ]}.
