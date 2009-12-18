-module(ns_port_sup).
-behavior(supervisor).

-export([start_link/0]).

-export([init/1, launch_port/2, launch_port/3, terminate_port/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one,
           get_env_default(max_r, 3),
           get_env_default(max_t, 10)},
          []}}.

get_env_default(Var, Def) ->
    case application:get_env(Var) of
        {ok, Value} -> Value;
        undefined -> Def
    end.

launch_port(Name, Cmd) ->
    launch_port(Name, Cmd, []).

launch_port(Name, Cmd, Args) when is_atom(Name); is_list(Cmd); is_list(Args) ->
    error_logger:info_msg("Supervising ~p~n", [Cmd]),
    supervisor:start_child(?MODULE, {Name,
                                     {ns_port_server, start_link, [Name, Cmd, Args]},
                                     permanent, 10, worker, [ns_port_server]}).

terminate_port(Name) ->
    error_logger:info_msg("Unsupervising ~p~n", [Name]),
    ok = supervisor:terminate_child(?MODULE, Name),
    ok = supervisor:delete_child(?MODULE, Name).
