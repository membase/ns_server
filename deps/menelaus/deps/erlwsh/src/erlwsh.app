{application, erlwsh,
 [{description, "erlwsh"},
  {vsn, "0.01"},
  {modules, [
    erlwsh,
    erlwsh_app,
    erlwsh_sup,
    erlwsh_web,
    erlwsh_deps
  ]},
  {registered, []},
  {mod, {erlwsh_app, []}},
  {env, []},
  {applications, [kernel, stdlib, crypto]}]}.
