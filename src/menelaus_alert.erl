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
         wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_logs/1,
         handle_alerts/1,
         handle_alerts_settings_post/1]).

-export([get_alert_config/0,
         set_alert_config/1]).

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
    reply_json(Req, {struct, [{settings,
                               {struct, [{updateUri,
                                          <<"/alerts/settings">>}
                                         | build_alert_settings()]}},
                              {list, build_alerts(Req:parse_qs())}]}).

handle_alerts_settings_post(Req) ->
    PostArgs = Req:parse_post(),
    AlertConfig = lists:keystore(alerts, 1, get_alert_config(), {alerts, []}),
    AlertConfig2 =
        lists:foldl(
          fun({"email", V}, C) ->
                  lists:keystore(email, 1, C, {email, V});
             ({"email_alerts", "1"}, C) ->
                  lists:keystore(email_alerts, 1, C, {email_alerts, true});
             ({"email_alerts", "0"}, C) ->
                  lists:keystore(email_alerts, 1, C, {email_alerts, false});
             ({[$s, $_ | K], "1"}, C) ->
                  case is_alert_key(K) of
                      true ->
                          lists:keystore(alerts, 1, C,
                                         {alerts,
                                          [list_to_atom(K) |
                                           proplists:get_value(alerts, C)]});
                      false -> C
                  end;
             (_, C) -> C
          end,
          AlertConfig,
          PostArgs),
    set_alert_config(AlertConfig2),
    Req:respond({200, [], []}).

build_alert_settings() ->
    C = get_alert_config(),
    [{email, list_to_binary(proplists:get_value(email, C, ""))},
     {sendAlerts, case proplists:get_value(email_alerts, C, false) of
                      true -> <<"1">>;
                      _    -> <<"0">>
                  end} |
     lists:map(fun(X) ->
                       {"s_" ++ atom_to_list(X), <<"1">>}
               end,
               proplists:get_value(alerts, C, []))].

build_logs(Params) ->
    {MinTStamp, Limit} = common_params(Params),
    build_log_structs(ns_log:recent(), MinTStamp, Limit).

build_log_structs(LogEntriesIn, MinTStamp, Limit) ->
    LogEntries = lists:filter(fun(#log_entry{tstamp = TStamp}) ->
                                      misc:time_to_epoch_int(TStamp) > MinTStamp
                              end,
                              LogEntriesIn),
    LogEntries2 = lists:reverse(lists:keysort(#log_entry.tstamp, LogEntries)),
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
                                     {tstamp, misc:time_to_epoch_int(TStamp)},
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
%  memory_low
%  bucket_created
%  config_changed

is_alert_key("server_down")    -> true;
is_alert_key("server_up")      -> true;
is_alert_key("server_joined")  -> true;
is_alert_key("memory_low")     -> true;
is_alert_key("bucket_created") -> true;
is_alert_key("config_changed") -> true;
is_alert_key(_) -> false.

alert_key(_Module, _Code) -> all.

default_alert_config() ->
    [{email, ""},
     {email_alerts, false},
     {alerts, []}].

get_alert_config() ->
    case ns_config:search(ns_config:get(), alerts) of
        {value, X} -> X;
        false      -> default_alert_config()
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

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

