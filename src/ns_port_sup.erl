%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ns_port_sup).

-behavior(supervisor).

-export([start_link/0, start_memcached_force_killer/0]).

-export([init/1, launch_port/1, terminate_port/1,
         restart_port/1, restart_port_by_name/1,
         expand_args/1,
         current_ports/0,
         port_servers_config/0]).

-include("ns_common.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_memcached_force_killer() ->
    misc:start_event_link(
      fun () ->
              CurrentMembership = ns_cluster_membership:get_cluster_membership(node()),
              ns_pubsub:subscribe_link(ns_config_events, fun memcached_force_killer_fn/2, CurrentMembership)
      end).

memcached_force_killer_fn({{node, Node, membership}, NewMembership}, PrevMembership) when Node =:= node() ->
    case NewMembership =:= inactiveFailed andalso PrevMembership =/= inactiveFailed of
        false ->
            ok;
        _ ->
            RV = (catch ns_port_memcached ! {send_to_port, <<"die!\n">>}),
            ?log_info("Sent force death command to own memcached: ~p", [RV])
    end,
    NewMembership;

memcached_force_killer_fn(_, State) ->
    State.

init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          [
           {ns_port_init,
            {ns_port_init, start_link, []},
            permanent, 10, worker, []}
           | dynamic_children()
          ]}}.

% Returns {value, PortServers}.

port_servers_config() ->
    ns_config:search_node(ns_config:get(), port_servers).

dynamic_children() ->
    {value, PortServers} = port_servers_config(),
    [create_child_spec(expand_args(NCAO)) || NCAO <- PortServers].

launch_port(NCAO) ->
    ?log_info("supervising port: ~p", [NCAO]),
    {ok, C} = supervisor:start_child(?MODULE,
                                     create_child_spec(NCAO)),
    {ok, C}.

expand_args({Name, Cmd, ArgsIn, OptsIn}) ->
    Config = ns_config:get(),
    %% Expand arguments
    Args = lists:map(fun ({Format, Keys}) ->
                             format(Config, Name, Format, Keys);
                           (X) -> X
                      end,
                      ArgsIn),
    %% Expand environment variables within OptsIn
    Opts = lists:map(
             fun ({env, Env}) ->
                     {env, lists:map(
                             fun ({Var, {Format, Keys}}) ->
                                     {Var, format(Config, Name, Format, Keys)};
                                 (X) -> X
                             end, Env)};
                 (X) -> X
             end, OptsIn),
    {Name, Cmd, Args, Opts}.

start_link_memcached_port(Name, Cmd, Args, Opts) ->
    case supervisor_cushion:start_link(Name, 5000, ns_port_server, start_link, [Name, Cmd, Args, Opts]) of
        {ok, Pid} = RV->
            try
                ChildPid = supervisor_cushion:child_pid(Pid),
                erlang:register(ns_port_memcached, ChildPid)
            catch T:E ->
                    ?log_error("failed to register ns_port_memcached. Eating exception and killing it: ~p", [{T, E}]),
                    exit(Pid, shutdown)
            end,
            RV;
        RV ->
            RV
    end.

%% memcached is sufficiently special so we register it, so that we can
%% kill it in start_memcached_force_killer
create_child_spec({memcached = Name, Cmd, Args, Opts}) ->
    {{Name, Cmd, Args, Opts},
     {erlang, apply, [fun start_link_memcached_port/4, [Name, Cmd, Args, Opts]]},
     permanent, 86400000, worker,
     [ns_port_server]};
create_child_spec({Name, Cmd, Args, Opts}) ->
    {{Name, Cmd, Args, Opts},
     {supervisor_cushion, start_link,
      [Name, 5000, ns_port_server, start_link, [Name, Cmd, Args, Opts]]},
     permanent, 10000, worker,
     [ns_port_server]}.

terminate_port(Id) ->
    ?log_info("unsupervising port: ~p", [Id]),
    ok = supervisor:terminate_child(?MODULE, Id),
    ok = supervisor:delete_child(?MODULE, Id).

restart_port(Id) ->
    ?log_info("restarting port: ~p", [Id]),
    ok = supervisor:terminate_child(?MODULE, Id),
    {ok, _} = supervisor:restart_child(?MODULE, Id).

restart_port_by_name(Name) ->
    Id = lists:keyfind(Name, 1, current_ports()),
    case Id of
        _ when Id =/= false ->
            restart_port(Id)
    end.

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
    Values = lists:map(fun ({Module, FuncName, Args}) -> erlang:apply(Module, FuncName, Args);
                           ({Key, SubKey}) -> ns_config:search_node_prop(Config, Key, SubKey);
                           (Key) -> ns_config:search_node_prop(Config, Name, Key)
                       end, Keys),
    lists:flatten(io_lib:format(Format, Values)).
