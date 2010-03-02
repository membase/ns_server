%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_alert).
-author('Northscale <info@northscale.com>').

-include("ns_log.hrl").

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2,
         validate_email_address/1,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_logs/1,
         handle_alerts/1,
         handle_alerts_settings_post/1,
         build_alerts_settings/0]).

-export([get_alert_config/0,
         set_alert_config/1,
         alert_key/2]).

-import(simple_cache, [call_simple_cache/2]).

-import(menelaus_util,
        [reply_json/2,
         java_date/0,
         stateful_takewhile/3,
         caching_result/2]).

%% External API

-define(DEFAULT_LIMIT, 50).

handle_logs(Req) ->
    reply_json(Req, {struct, [{list, build_logs(Req:parse_qs())}]}).

handle_alerts(Req) ->
    reply_json(Req, {struct, [{list, build_alerts(Req:parse_qs())}]}).

% The PostArgs looks like a single flat key-value map, like the json of...
%
%   {"email": "joe@rock.com",
%    "alert_server_up": "1",
%    "alert_server_joined": "0",
%    "email_server_port": "587"}
%
handle_alerts_settings_post(PostArgs) ->
    AlertConfig = lists:keystore(alerts, 1, get_alert_config(), {alerts, []}),
    AlertConfig2 =
        lists:foldl(
          fun({"email", V}, C) ->
                  lists:keystore(email, 1, C, {email, V});
             ({"sender", V}, C) ->
                  lists:keystore(sender, 1, C, {sender, V});
             ({"email_alerts", "1"}, C) ->
                  lists:keystore(email_alerts, 1, C, {email_alerts, true});
             ({"email_alerts", "0"}, C) ->
                  lists:keystore(email_alerts, 1, C, {email_alerts, false});
             ({[$a, $l, $e, $r, $t, $_ | K], "1"}, C) ->
                  case is_alert_key(K) of
                      true ->
                          lists:keystore(
                            alerts, 1, C,
                            {alerts,
                             [list_to_existing_atom(K) |
                              proplists:get_value(alerts, C)]});
                      false -> C
                  end;
             ({"email_server_encrypt", "1"}, C) ->
                  set_subkey(email_server, encrypt, true, C);
             ({"email_server_encrypt", "0"}, C) ->
                  set_subkey(email_server, encrypt, false, C);
             ({K, V}, C) ->
                  case string:tokens(K, "_") of
                      ["email", "server", K2] ->
                          case is_email_server_key(K2) of
                              true ->
                                  set_subkey(email_server,
                                             list_to_existing_atom(K2),
                                             V, C);
                              false -> C
                          end;
                      _ -> C
                  end;
             (_, C) -> C
          end,
          AlertConfig,
          PostArgs),
    case validate_alert_config(AlertConfig2) of
        [] -> {ok, fun () ->
                           set_alert_config(AlertConfig2)
                   end};
        Errors -> {errors, Errors}
    end.

set_subkey(Key, SubKey, V, Config) ->
    S = proplists:get_value(Key, Config),
    lists:keystore(Key, 1, Config, {Key,
                                    lists:keystore(SubKey, 1, S,
                                                   {SubKey, V})}).

build_alerts_settings() ->
    C = get_alert_config(),
    S = proplists:get_value(email_server, C, []),
    [{email, list_to_binary(proplists:get_value(email, C, ""))},
     {sender, list_to_binary(proplists:get_value(sender, C, ""))},
     {email_server,
      {struct, [{user, bin_string(proplists:get_value(user, S, ""))},
                {pass, bin_string(proplists:get_value(pass, S, ""))},
                {addr, bin_string(proplists:get_value(addr, S, ""))},
                {port, bin_string(proplists:get_value(port, S, ""))},
                {encrypt, bin_boolean(proplists:get_value(encrypt, S, false))}
               ]}},
     {sendAlerts, bin_boolean(proplists:get_value(email_alerts, C, false))},
     {alerts,
      {struct, lists:map(fun(X) -> {atom_to_list(X), <<"1">>}
                         end,
                         proplists:get_value(alerts, C, []))}}].

build_logs(Params) ->
    {MinTStamp, Limit} = common_params(Params),
    build_log_structs(ns_log:recent(), MinTStamp, Limit).

build_log_structs(LogEntriesIn, MinTStamp, Limit) ->
    LogEntries = lists:filter(fun(#log_entry{tstamp = TStamp}) ->
                                      misc:time_to_epoch_ms_int(TStamp) > MinTStamp
                              end,
                              LogEntriesIn),
    LogEntries2 = lists:keysort(#log_entry.tstamp, LogEntries),
    LogEntries3 = lists:sublist(LogEntries2, Limit),
    LogStructs =
        lists:foldl(
          fun(#log_entry{module = Module,
                         code = Code,
                         msg = Msg,
                         args = Args,
                         cat = Cat,
                         tstamp = TStamp}, Acc) ->
                  case catch(io_lib:format(Msg, Args)) of
                      S when is_list(S) ->
                          CodeString = ns_log:code_string(Module, Code),
                          [{struct, [{type, category_bin(Cat)},
                                     {code, Code},
                                     {module, list_to_binary(atom_to_list(Module))},
                                     {tstamp, misc:time_to_epoch_ms_int(TStamp)},
                                     {shortText, list_to_binary(CodeString)},
                                     {text, list_to_binary(S)}]} | Acc];
                      _ -> Acc
                  end
          end,
          [],
          LogEntries3),
    LogStructs.

category_bin(info) -> <<"info">>;
category_bin(warn) -> <<"warning">>;
category_bin(crit) -> <<"critical">>;
category_bin(_)    -> <<"info">>.

build_alerts(Params) ->
    {MinTStamp, Limit} = common_params(Params),
    AlertConfig = get_alert_config(),
    Alerts = proplists:get_value(alerts, AlertConfig, []),
    LogEntries = ns_log:recent(),
    LogEntries2 = lists:filter(
                    fun(#log_entry{module = Module,
                                   code = Code}) ->
                            lists:member(alert_key(Module, Code), Alerts)
                    end,
                    LogEntries),
    build_log_structs(LogEntries2, MinTStamp, Limit).

% The defined alert_key() responses are...
%
%  server_down
%  server_up
%  server_joined
%  server_left
%  bucket_created
%  bucket_deleted
%  bucket_auth_failed

is_alert_key("server_down")    -> true;
is_alert_key("server_up")      -> true;
is_alert_key("server_joined")  -> true;
is_alert_key("server_left")    -> true;
is_alert_key("bucket_created") -> true;
is_alert_key("bucket_deleted") -> true;
is_alert_key("bucket_auth_failed") -> true;
is_alert_key(_) -> false.

alert_key(ns_node_disco, 0005) -> server_down;
alert_key(ns_node_disco, 0004) -> server_up;
alert_key(menelaus_web, 0009)  -> server_joined;
alert_key(menelaus_web, 0013)  -> server_left;
alert_key(menelaus_web, 0012)  -> bucket_created;
alert_key(menelaus_web, 0011)  -> bucket_deleted;
alert_key(mc_pool, 0006)       -> bucket_auth_failed;
alert_key(_Module, _Code) -> all.

is_email_server_key("user")    -> true;
is_email_server_key("pass")    -> true;
is_email_server_key("addr")    -> true;
is_email_server_key("port")    -> true;
is_email_server_key("encrypt") -> true;
is_email_server_key(_)         -> false.

default_alert_config() ->
    [{email, ""},
     {email_alerts, false},
     {alerts, []}].

get_alert_config() ->
    case ns_config:search(ns_config:get(), alerts) of
        {value, X} -> X;
        false      -> default_alert_config()
    end.


validate_alert_config(AlertConfig) ->
    EmailServer = proplists:get_value(email_server, AlertConfig, []),
    case proplists:get_value(email_alerts, AlertConfig) of
        true ->
            Candidates = [validate_email_address(proplists:get_value(sender, AlertConfig, []))
                          orelse <<"Sender field is not valid email address">>,
                          validate_email_address(proplists:get_value(email, AlertConfig, []))
                          orelse <<"Email field is not valid email address">>,
                          proplists:get_value(addr, EmailServer, []) =/= ""
                          orelse <<"Email server name field cannot be blank">>,
                          proplists:get_value(port, EmailServer, []) =/= ""
                          orelse <<"Email server port field cannot be blank">>],
            lists:filter(fun (C) -> C =/= true end,
                         Candidates);
        _ -> []
    end.

set_alert_config(AlertConfig) ->
    ns_config:set(alerts, AlertConfig).

common_params(Params) ->
    MinTStamp = case proplists:get_value("sinceTime", Params) of
                     undefined -> 0;
                     V -> list_to_integer(V)
                 end,
    Limit = case proplists:get_value("limit", Params) of
                undefined -> ?DEFAULT_LIMIT;
                L -> list_to_integer(L)
            end,
    {MinTStamp, Limit}.

bin_boolean(true) -> <<"1">>;
bin_boolean(_)    -> <<"0">>.

bin_string(undefined) -> <<"">>;
bin_string(S)         -> list_to_binary(S).

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

