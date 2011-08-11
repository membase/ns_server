%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(cb_config_couch_sync).

-behaviour(gen_event).

-export([start_link/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-include("ns_common.hrl").

-record(state, {}).

start_link() ->
    misc:start_event_link(
      fun () ->
              gen_event:add_sup_handler(ns_config_events,
                                        {?MODULE, ns_config_events},
                                        [])
      end).

init([]) ->
    {value, CouchConf} = ns_config:search_node(couchdb),
    update_couchdb_config(CouchConf),
    {ok, #state{}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _) ->
    {ok, State}.

handle_call(Request, State) ->
    ?log_info("handle_call(~p, ~p)", [Request, State]),
    {ok, State}.

handle_info(Info, State) ->
    ?log_info("handle_info(~p, ~p)", [Info, State]),
    {ok, State}.

handle_event({{node, Node, couchdb}, Config}, State) when Node =:= node() ->
    update_couchdb_config(Config),
    {ok, State};

handle_event(_Event, State) ->
    {ok, State}.

%% Auxiliary functions.
update_couchdb_config(Config) ->
    %% Updates couch config. Returns true if couchdb needs to be restarted.
    MaybeUpdate =
        fun ({Key, Value}) ->
                KeyStr = atom_to_list(Key),
                Current = couch_config:get("couchdb", KeyStr),

                case Value of
                    Current ->
                        false;
                    _ ->
                        ?log_info("Updating couchdb config: ~p (~p -> ~p)",
                                  [Key, Current, Value]),
                        ok = couch_config:set("couchdb", KeyStr, Value),
                        requires_couch_restart(Key)
                end
        end,

    Results = lists:map(MaybeUpdate, Config),
    Id = fun (X) -> X end,
    case lists:any(Id, Results) of
        true ->
            ?log_info("Restarting couchdb."),
            cb_couch_sup:restart_couch();
        false ->
            ok
    end.

requires_couch_restart(database_dir) ->
    true;
requires_couch_restart(view_index_dir) ->
    true;
requires_couch_restart(_Other) ->
    false.
