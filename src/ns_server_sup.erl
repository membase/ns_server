-module(ns_server_sup).
-behavior(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{rest_for_one,
           get_env_default(max_r, 3),
           get_env_default(max_t, 10)},
          get_child_specs()}}.

get_env_default(Var, Def) ->
    case application:get_env(Var) of
        {ok, Value} -> Value;
        undefined -> Def
    end.

get_child_specs() ->
    [
     % Insert stuff to be supervised here.
    ].
