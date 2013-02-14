%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
%% @doc this implements simple replica of ns_config as public ets
%% table. Thus benefit is being real quick. But note that it
%% potentially lags behind ns_config.
-module(ns_config_ets_dup).

-export([start_link/0, unreliable_read_key/2, get_timeout/2]).

start_link() ->
    misc:start_event_link(
      fun () ->
              ets:new(ns_config_ets_dup, [public, set, named_table]),
              ns_pubsub:subscribe_link(ns_config_events, fun event_loop/1),
              ns_config:reannounce()
      end).

event_loop({_K, _V} = Pair) ->
    ets:insert(ns_config_ets_dup, Pair);
event_loop(_SomethingElse) ->
    ok.

unreliable_read_key(Key, Default) ->
    case ets:lookup(ns_config_ets_dup, Key) of
        [{_, V}] ->
            V;
        _ -> Default
    end.

get_timeout(Operation, Default) ->
    unreliable_read_key({node, node(), {timeout, Operation}}, Default).
