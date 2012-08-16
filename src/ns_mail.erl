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
-module(ns_mail).

-export([send/3, send_alert/3]).

-include("ns_common.hrl").


%% API

send(Subject, Body, Config) ->
    Sender = proplists:get_value(sender, Config),
    Recipients = proplists:get_value(recipients, Config),
    ServerConfig = proplists:get_value(email_server, Config),
    Options = config_to_options(ServerConfig),

    do_send(Sender, Recipients, Subject, Body, Options).

send_alert(AlertKey, Message, Config) when is_atom(AlertKey) ->
    EnabledAlerts = proplists:get_value(alerts, Config, []),
    case lists:member(AlertKey, EnabledAlerts) of
        true ->
            Subject = "Couchbase Server alert: " ++ atom_to_list(AlertKey),
            send(Subject, Message, Config);
        false ->
            ok
    end.

%% Internal functions

do_send(Sender, Rcpts, Subject, Body, Options) ->
    Message0 = mimemail:encode({<<"text">>, <<"plain">>,
                                make_headers(Sender, Rcpts, Subject), [],
                                list_to_binary(Body)}),
    Message = binary_to_list(Message0),
    Reply = gen_smtp_client:send_blocking({Sender, Rcpts, Message}, Options),
    case Reply of
        {error, _, Reason} ->
            ale:warn(?USER_LOGGER,
                     "Could not send email: ~p. "
                     "Make sure that your email settings are correct.", [Reason]);
        _ ->
            ok
    end,
    Reply.

%% Internal functions

format_addr(Rcpts) ->
    string:join(["<" ++ Addr ++ ">" || Addr <- Rcpts], ", ").

make_headers(Sender, Rcpts, Subject) ->
    [{<<"From">>, list_to_binary(format_addr([Sender]))},
     {<<"To">>, list_to_binary(format_addr(Rcpts))},
     {<<"Subject">>, list_to_binary(Subject)}].

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
