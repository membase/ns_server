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
          [
           {ns_port_init,
            {ns_port_init, start, []},
            transient, 10, worker, []}
           | dynamic_children()
          ]}}.

get_env_default(Var, Def) ->
    case application:get_env(Var) of
        {ok, Value} -> Value;
        undefined -> Def
    end.

dynamic_children() ->
    {value, PortServers} = ns_config:search(ns_config:get(), port_servers),
    error_logger:info_msg("Initializing ports: ~p~n", [PortServers]),
    lists:map(fun create_child_spec/1, PortServers).

launch_port(Name, Cmd) ->
    launch_port(Name, Cmd, []).

launch_port(Name, Cmd, Args) when is_atom(Name); is_list(Cmd); is_list(Args) ->
    error_logger:info_msg("Supervising ~p~n", [Cmd]),
    {ok, C} = supervisor:start_child(?MODULE,
                                     create_child_spec({Name, Cmd, Args})),
    error_logger:info_msg("New child is ~p~n", [C]),
    {ok, C}.

create_child_spec({Name, Cmd, Args}) ->
    {Name,
     {ns_port_server, start_link,
      [Name, Cmd, Args]},
     permanent, 10, worker,
     [ns_port_server]}.

terminate_port(Name) ->
    error_logger:info_msg("Unsupervising ~p~n", [Name]),
    ok = supervisor:terminate_child(?MODULE, Name),
    ok = supervisor:delete_child(?MODULE, Name).
