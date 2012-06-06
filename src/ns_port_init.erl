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
-module(ns_port_init).

-behaviour(gen_event).

-export([start_link/0, reconfig/1]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {
          old_port_servers_config
         }).

% Noop process to get initialized in the supervision tree.
start_link() ->
    misc:start_event_link(fun () ->
                                  gen_event:add_sup_handler(ns_config_events, ?MODULE, ignored)
                          end).

init(ignored) ->
    {ok, #state{}}.

handle_event(Event, State) ->
    case is_useless_event(Event) of
        true ->
            {ok, State};
        false ->
            {value, PortServers} = ns_port_sup:port_servers_config(),
            PortParams = [ns_port_sup:expand_args(NCAO) || NCAO <- PortServers],
            case State#state.old_port_servers_config =:= PortParams of
                true ->
                    {ok, State};
                false ->
                    ok = reconfig(PortParams),
                    {ok, State#state{old_port_servers_config = PortParams}}
            end
    end.

%% ns_config announces full list as well which we don't need
is_useless_event(List) when is_list(List) ->
    true;
%% buckets are frequently changing and are generally useless for port
%% servers
is_useless_event({buckets, _}) ->
    true;
%% config changes for other nodes is quite obviously irrelevant
is_useless_event({{node, N, _}, _}) when N =/= node() ->
    true;
is_useless_event(_) ->
    false.

handle_call(unhandled, unhandled) ->
    unhandled.

handle_info(_, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

reconfig(PortParams) ->
    % CurrPorts looks like...
    %   [{memcached,<0.77.0>,worker,[ns_port_server]}]
    % Or, if the child process went down, then...
    %   [{memcached,undefined,worker,[ns_port_server]}]
    %
    CurrPortParams = ns_port_sup:current_ports(),
    OldPortParams = CurrPortParams -- PortParams,
    NewPortParams = PortParams -- CurrPortParams,

    lists:foreach(fun(NCAO) ->
                      ns_port_sup:terminate_port(NCAO)
                  end,
                  OldPortParams),
    lists:foreach(fun(NCAO) ->
                      ns_port_sup:launch_port(NCAO)
                  end,
                  NewPortParams),
    ok.
