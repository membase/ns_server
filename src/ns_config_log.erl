%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
-module(ns_config_log).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-include("ns_common.hrl").

-record(state, {last}).

start_link() ->
    misc:start_event_link(fun () ->
                                  gen_event:add_sup_handler(ns_config_events, ?MODULE, ignored)
                          end).

init(ignored) ->
    {ok, #state{last = undefined}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

% Don't log values for some password/auth-related config values.

handle_event({rest_creds = K, _V}, State) ->
    ?log_info("config change: ~p -> ********", [K]),
    {ok, State, hibernate};
handle_event({alerts = K, V}, State) ->
    V2 = lists:map(fun({email_server, ES}) ->
                           lists:map(fun({pass, _}) -> {pass, "********"};
                                        (ESKeyVal)  -> ESKeyVal
                                     end,
                                     ES);
                      (V2KeyVal) -> V2KeyVal
                   end,
                   V),
    ?log_info("config change:~n~p ->~n~p", [K, V2]),
    {ok, State, hibernate};
handle_event({K, V}, State) ->
    %% These can get pretty big, so pre-format them for the logger.
    VB = list_to_binary(io_lib:print(V, 0, 80, 100)),
    ?log_info("config change:~n~p ->~n~s", [K, VB]),
    {ok, State, hibernate};

handle_event(KVList, State) when is_list(KVList) ->
    {ok, State#state{last = KVList}, hibernate};

handle_event(_, State) ->
    {ok, State, hibernate}.

handle_call(Request, State) ->
    ?log_info("handle_call(~p, ~p)", [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(_Info, State) ->
    {ok, State, hibernate}.
