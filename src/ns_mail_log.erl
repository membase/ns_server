% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_mail_log).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

-include_lib("eunit/include/eunit.hrl").

%% gen_event handlers

% Noop process to get initialized in the supervision tree.
start_link() ->
    {ok, spawn_link(fun() ->
                       gen_event:add_handler(ns_log_events,
                                             ?MODULE,
                                             ns_log_events)
                    end)}.

init(_) ->
    {ok, #state{}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({ns_log, _Category, Module, Code, Fmt, Args}, State) ->
    AlertConfig = try menelaus_alert:get_alert_config() catch _:Reason ->
        error_logger:info_msg("ns_mail_log: unable to get alert config from menelaus_alert: ~p~n",
                              [Reason]),
        []
    end,
    case proplists:get_bool(email_alerts, AlertConfig) of
        true ->
            AlertKey = menelaus_alert:alert_key(Module, Code),
            Alerts = proplists:get_value(alerts, AlertConfig, []),
            case lists:member(AlertKey, Alerts) of
                true -> send_email(proplists:get_value(sender, AlertConfig, "northscale"),
                                   proplists:get_value(email, AlertConfig),
                                   AlertKey,
                                   lists:flatten(io_lib:format(Fmt, Args)),
                                   proplists:get_value(email_server, AlertConfig));
                false -> ok
            end;
        false -> ok
    end,
    {ok, State, hibernate};
handle_event(Event, State) ->
    error_logger:info_msg("ns_mail_log handle_event(~p, ~p)~n",
                          [Event, State]),
    {ok, State, hibernate}.

handle_call(Request, State) ->
    error_logger:info_msg("ns_mail_log handle_call(~p, ~p)~n",
                          [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("ns_mail_log handle_info(~p, ~p)~n",
                          [Info, State]),
    {ok, State, hibernate}.

%% Internal functions

config_to_options(ServerConfig) ->
    Username = proplists:get_value(user, ServerConfig),
    Password = proplists:get_value(pass, ServerConfig),
    Relay = proplists:get_value(addr, ServerConfig),
    Port = proplists:get_value(port, ServerConfig),
    Encrypt = proplists:get_bool(encrypt, ServerConfig),
    Options = [{relay, Relay}],
    Options2 = case Username of
        undefined -> Options;
        _ -> lists:append(Options, [{username, Username}, {password, Password}])
    end,
    Options3 = case Encrypt of
        true -> [{tls, always} | Options2];
        false -> Options2
    end,
    case Port of
        undefined -> Options3;
        _ -> [{port, list_to_integer(Port)} | Options3]
    end.

send_email(Sender, Rcpt, AlertKey, Message, ServerConfig) ->
    Options = config_to_options(ServerConfig),
    Subject = "NorthScale alert: " ++ atom_to_list(AlertKey),
    ns_mail:send(Sender, [Rcpt], Subject, Message, Options).
