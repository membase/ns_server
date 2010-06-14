% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_port_sup).

-behavior(supervisor).

-export([start_link/0]).

-export([init/1, launch_port/1, terminate_port/1,
         expand_args/1,
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
    ns_config:search_node(ns_config:get(), port_servers).

dynamic_children() ->
    {value, PortServers} = port_servers_config(),
    error_logger:info_msg("dynamic_children PortServers=~p~n", [PortServers]),
    error_logger:info_msg("initializing ports: ~p~n", [PortServers]),
    [create_child_spec(expand_args(NCAO)) || NCAO <- PortServers].

launch_port(NCAO) ->
    error_logger:info_msg("supervising port: ~p~n", [NCAO]),
    {ok, C} = supervisor:start_child(?MODULE,
                                     create_child_spec(NCAO)),
    error_logger:info_msg("new child port: ~p~n", [C]),
    {ok, C}.

expand_args({Name, Cmd, ArgsIn, Opts}) ->
    error_logger:info_msg("expand_args args: ~p~n", [{Name, Cmd, ArgsIn, Opts}]),
    Config = ns_config:get(),
    Args = lists:map(fun ({Format, Keys}) ->
                             format(Config, Name, Format, Keys);
                           (X) -> X
                      end,
                      ArgsIn),
    {Name, Cmd, Args, Opts}.

create_child_spec({Name, Cmd, Args, Opts}) ->
    {{Name, Cmd, Args, Opts},
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
    [NCAO || {NCAO, Pid, _, _} <- Children,
             Pid /= undefined,
             NCAO /= ns_port_init].

%% internal functions
format(Config, Name, Format, Keys) ->
    error_logger:info_msg("format args ~p~n", [[Name, Format, Keys]]),
    Values = [ns_config:search_node_prop(Config, Name, K) || K <- Keys],
    lists:flatten(io_lib:format(Format, Values)).

