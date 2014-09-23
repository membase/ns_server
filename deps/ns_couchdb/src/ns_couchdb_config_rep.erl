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
%%
%% @doc process responsible for ns_config replication from ns_server to
%% ns_couchdb node
%%

-module(ns_couchdb_config_rep).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MERGING_EMERGENCY_THRESHOLD, 2000).
-define(PULL_TIMEOUT, 30000).

start_link() ->
    gen_server:start_link({local, ns_config_rep}, ?MODULE, [], []).

init([]) ->
    {ok, []}.

schedule_config_pull() ->
    Frequency = 5000 + trunc(random:uniform() * 55000),
    timer2:send_after(Frequency, self(), pull).

do_pull() ->
    Node = ns_node_disco:ns_server_node(),
    ?log_info("Pulling config from: ~p~n", [Node]),
    case (catch ns_config_rep:get_remote(Node, ?PULL_TIMEOUT)) of
        {'EXIT', _, _} ->
            ok;
        {'EXIT', _} ->
            ok;
        KVList ->
            KVList1 = ns_config:duplicate_node_keys(KVList, Node, node()),
            ns_config:set(KVList1),
            ok
    end.

handle_call(Msg, _From, State) ->
    ?log_warning("Unhandled call: ~p", [Msg]),
    {reply, error, State}.

handle_cast({merge_compressed, Blob}, State) ->
    KVList = binary_to_term(zlib:uncompress(Blob)),
    KVList1 = ns_config:duplicate_node_keys(KVList, ns_node_disco:ns_server_node(), node()),

    ns_config:set(KVList1),

    {message_queue_len, QL} = erlang:process_info(self(), message_queue_len),
    case QL > ?MERGING_EMERGENCY_THRESHOLD of
        true ->
            ?log_warning("Queue size emergency state reached. "
                         "Will kill myself and resync"),
            exit(emergency_kill);
        false -> ok
    end,
    {noreply, State};
handle_cast(Msg, State) ->
    ?log_error("Unhandled cast: ~p", [Msg]),
    {noreply, State}.

handle_info(pull, State) ->
    schedule_config_pull(),
    do_pull(),
    {noreply, State};
handle_info(Msg, State) ->
    ?log_debug("Unhandled msg: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
