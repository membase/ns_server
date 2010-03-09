% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_port_sup).

-behavior(supervisor).

-export([start_link/0]).

-export([init/1, launch_port/2, launch_port/4, terminate_port/1,
         current_ports/0,
         port_servers_config/0]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          [
           {ns_port_init,
            {ns_port_init, start_link, []},
            transient, 10, worker, []}
           | dynamic_children()
          ]}}.

% Returns {value, PortServers}.

port_servers_config() ->
    Config = ns_config:get(),
    case ns_config:search(Config, {node, node(), port_servers}) of
        false -> ns_config:search(Config, port_servers);
        X     -> X
    end.

dynamic_children() ->
    {value, PortServers} = port_servers_config(),
    error_logger:info_msg("initializing ports: ~p~n", [PortServers]),
    lists:map(fun create_child_spec/1, PortServers).

launch_port(Name, Cmd) ->
    launch_port(Name, Cmd, [], []).

launch_port(Name, Cmd, Args, Opts)
  when is_atom(Name); is_list(Cmd); is_list(Args) ->
    error_logger:info_msg("supervising port: ~p~n", [Cmd]),
    {ok, C} = supervisor:start_child(?MODULE,
                                     create_child_spec({Name, Cmd, Args, Opts})),
    error_logger:info_msg("new child port: ~p~n", [C]),
    {ok, C}.

create_child_spec({Name, Cmd, Args, Opts}) ->
    {Name,
     {supervisor_cushion, start_link,
      [Name, 5000, ns_port_server, start_link, [Name, Cmd, Args, Opts]]},
     permanent, 10, worker,
     [ns_port_server]}.

terminate_port(Name) ->
    error_logger:info_msg("unsupervising port: ~p~n", [Name]),
    ok = supervisor:terminate_child(?MODULE, Name),
    ok = supervisor:delete_child(?MODULE, Name).

current_ports() ->
    % Children will look like...
    %   [{memcached,<0.77.0>,worker,[ns_port_server]},
    %    {ns_port_init,undefined,worker,[]}]
    %
    % Or possibly, if a child died, like...
    %   [{memcached,undefined,worker,[ns_port_server]},
    %    {ns_port_init,undefined,worker,[]}]
    %
    Children = supervisor:which_children(?MODULE),
    misc:mapfilter(fun ({ns_port_init, _, _, _}) ->
                           false;
                       ({_, undefined, _, _}) ->
                           false;
                       ({Name, Pid, Args, Opts}) ->
                           case supervisor_cushion:child_pid(Pid) of
                           undefined -> false;
                           ChildPid ->
                               % Return the PID of the cushion's child
                               % so stuff can talk to it.
                               {Name, ChildPid, Args, Opts}
                           end
                   end, false, Children).

