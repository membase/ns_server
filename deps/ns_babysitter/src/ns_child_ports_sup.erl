%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc
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
-module(ns_child_ports_sup).

-behavior(supervisor).

-export([start_link/0, set_dynamic_children/1,
         send_command/2,
         create_ns_server_supervisor_spec/0]).

-export([init/1, launch_port/1, terminate_port/1,
         restart_port/1, restart_port_by_name/1,
         current_ports/0, find_port/1]).

-include("ns_common.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.

send_command(PortName, Command) ->
    try
        do_send_command(PortName, Command)
    catch T:E ->
            ?log_error("Failed to send command ~p to port ~p due to ~p:~p. Ignoring...~n~p",
                       [Command, PortName, T, E, erlang:get_stacktrace()]),
            {T, E}
    end.

find_port(PortName) ->
    Childs = supervisor:which_children(?MODULE),
    [Pid] = [Pid || {{Name, _, _, _}, Pid, _, _} <- Childs,
                    Pid =/= undefined,
                    Name =:= PortName],
    Pid.

do_send_command(PortName, Command) ->
    Pid = find_port(PortName),
    Pid ! {send_to_port, Command}.

-spec set_dynamic_children([any()]) -> pid().
set_dynamic_children(NCAOs) ->
    PlainCurrPortParams = current_ports(),
    CurrPortParams = PlainCurrPortParams,
    OldPortParams = CurrPortParams -- NCAOs,
    NewPortParams = NCAOs -- CurrPortParams,

    PidBefore = erlang:whereis(?MODULE),

    lists:foreach(fun(NCAO) ->
                          terminate_port(NCAO)
                  end,
                  OldPortParams),
    lists:foreach(fun(NCAO) ->
                          launch_port(NCAO)
                  end,
                  NewPortParams),

    PidAfter = erlang:whereis(?MODULE),
    PidBefore = PidAfter.


launch_port(NCAO) ->
    ?log_info("supervising port: ~p", [NCAO]),
    {ok, C} = supervisor:start_child(?MODULE,
                                     create_child_spec(NCAO)),
    {ok, C}.

create_ns_server_supervisor_spec() ->
    [{spawn_executable, ErlCmd}, [{args, NSServerArgs} | NSServerOpts]] = child_erlang:open_port_args(),

    Options0 = [port_server_send_eol | NSServerOpts],
    Options = case misc:get_env_default(ns_server, dont_suppress_stderr_logger, false) of
                  true ->
                      [ns_server_no_stderr_to_stdout | Options0];
                  _ ->
                      Options0
              end,

    NCAO = {ns_server, ErlCmd, NSServerArgs, Options},
    create_child_spec(NCAO).

create_child_spec({Name, Cmd, Args, Opts}) ->
    {{Name, Cmd, Args, Opts},
     {supervisor_cushion, start_link,
      [Name, 5000, infinity, ns_port_server, start_link, [Name, Cmd, Args, Opts]]},
     permanent, 86400000, worker,
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
             Pid /= undefined].
