{application, menelaus_server,
 [{description, "menelaus_server"},
  {vsn, "0.01"},
  {modules, [
    menelaus_server,
    menelaus_server_app,
    menelaus_server_sup,
    menelaus_server_web,
    menelaus_server_deps
  ]},
  {registered, []},
  {mod, {menelaus_server_app, []}},
  {env, []},
  {applications, [kernel, stdlib, crypto]}]}.
