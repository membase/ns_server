{application, ns_server_app,
 [{description, "The NorthScale smart server."},
  {vsn, "1.0"},
  {modules, [ns_server_app]},
  {registered, [ns_server_app]},
  {applications, [kernel, stdlib]},
  {mod, {ns_server_app, []}},

  % To  prevent  a  supervisor  from getting into an infinite loop of child
  % process terminations and  restarts,  a  maximum  restart  frequency  is
  % defined  using  two  integer  values  MaxR  and MaxT. If more than MaxR
  % restarts occur within MaxT seconds, the supervisor terminates all child
  % processes and then itself.

  {env, [{max_r, 3}, {max_t, 10}]}
 ]}.
