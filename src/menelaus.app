{application, menelaus,
 [{description, "menelaus"},
  {vsn, "0.01"},
  {modules, [
    menelaus,
    menelaus_app,
    menelaus_sup,
    menelaus_web,
    menelaus_deps,
    simple_cache
  ]},
  {registered, []},
  {mod, {menelaus_app, []}},
  {env, []},
  {applications, [kernel, stdlib, crypto]}]}.
