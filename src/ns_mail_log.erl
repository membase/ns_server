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
-module(ns_mail_log).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).
%% API
-export([send_email_with_config/3]).

-record(state, {}).

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").

%% gen_event handlers

% Noop process to get initialized in the supervision tree.
start_link() ->
    misc:start_event_link(fun () ->
                                  gen_event:add_sup_handler(ns_log_events,
                                                            ?MODULE,
                                                            ns_log_events)
                          end).

init(_) ->
    ?log_debug("ns_mail_log started up", []),
    {ok, #state{}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({ns_log, _Category, Module, Code, Fmt, Args}, State) ->
    {value, Config} = ns_config:search(email_alerts),
    case proplists:get_bool(enabled, Config) of
        true ->
            AlertKey = menelaus_alert:alert_key(Module, Code),
            EnabledAlerts = proplists:get_value(alerts, Config, []),
            case lists:member(AlertKey, EnabledAlerts) of
                true ->
                    send_email(proplists:get_value(sender, Config),
                               proplists:get_value(recipients, Config),
                               AlertKey,
                               lists:flatten(io_lib:format(Fmt, Args)),
                               proplists:get_value(email_server, Config));
                false ->
                    ok
            end;
        false -> ok
    end,
    {ok, State, hibernate};
handle_event(Event, State) ->
    ?log_debug("ns_mail_log handle_event(~p, ~p)~n", [Event, State]),
    {ok, State, hibernate}.

handle_call(Request, State) ->
    ?log_warning("Unexpected handle_call(~p, ~p)~n", [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    ?log_warning("Unexpected handle_info(~p, ~p)~n", [Info, State]),
    {ok, State, hibernate}.

%% @doc Sends an email with the given configuration
send_email_with_config(Subject, Body, Config) ->
    ServerConfig = proplists:get_value(email_server, Config),
    Options = config_to_options(ServerConfig),
    ns_mail:send(proplists:get_value(sender, Config),
                 proplists:get_value(recipients, Config),
                 Subject, Body, Options).


%% Internal functions

config_to_options(ServerConfig) ->
    Username = proplists:get_value(user, ServerConfig),
    Password = proplists:get_value(pass, ServerConfig),
    Relay = proplists:get_value(host, ServerConfig),
    Port = proplists:get_value(port, ServerConfig),
    Encrypt = proplists:get_bool(encrypt, ServerConfig),
    Options = [{relay, Relay}, {port, Port}],
    Options2 = case Username of
        "" ->
            Options;
        _ ->
            [{username, Username}, {password, Password}] ++ Options
    end,
    case Encrypt of
        true -> [{tls, always} | Options2];
        false -> Options2
    end.

send_email(Sender, Rcpts, AlertKey, Message, ServerConfig) ->
    Options = config_to_options(ServerConfig),
    Subject = "Couchbase Server alert: " ++ atom_to_list(AlertKey),
    ns_mail:send(Sender, Rcpts, Subject, Message, Options).
