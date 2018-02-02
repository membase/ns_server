%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
-module(xdcr_trace_log_formatter).

%% this is endpoint used by ale
-export([format_msg/2]).

%% this is util functions
-export([format_pid/1,
         format_ts/1,
         format_pp/1]).

-include_lib("ale/include/ale.hrl").
-include("ns_common.hrl").

format_msg(#log_info{user_data = {Pid, Type, KV},
                     module = M,
                     function = F,
                     line = L,
                     time = TS}, []) ->
    KV1 = [case V of
               _ when is_list(V) -> {K, list_to_binary(V)};
               {json, RealV} -> {K, RealV};
               _ when is_pid(V) -> {K, format_pid(V)};
               _ -> {K, V}
           end || {K, V} <- KV,
                  V =/= undefined],

    Loc = io_lib:format("~s:~s:~B", [M, F, L]),

    JSON = ejson:encode({[{pid, list_to_binary(erlang:pid_to_list(Pid))},
                          {type, Type},
                          {ts, misc:time_to_epoch_float(TS)}
                          | KV1] ++ [{loc, iolist_to_binary(Loc)}]}),
    [JSON, $\n];
format_msg(_, _) ->
    [].

format_pid(Pid) ->
    erlang:list_to_binary(erlang:pid_to_list(Pid)).

format_ts(Time) ->
    misc:time_to_epoch_float(Time).

format_pp(Reason) ->
    case ale:is_loglevel_enabled(?XDCR_TRACE_LOGGER, debug) of
        true ->
            iolist_to_binary(io_lib:format("~p", [Reason]));
        _ ->
            []
    end.
