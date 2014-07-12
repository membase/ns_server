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
%% @doc stab for compatibility with pre 3.0 nodes, that call compaction_daemon
%% remotely as an fsm
%%
-module(compaction_daemon).

-behaviour(gen_fsm).

-include("ns_common.hrl").
-include("couch_db.hrl").

%% API
-export([start_link/0,
         inhibit_view_compaction/3, uninhibit_view_compaction/3]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         code_change/4, terminate/3]).

%% API
start_link() ->
    gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec inhibit_view_compaction(bucket_name(), node(), pid()) ->
                                     {ok, reference()} | nack.
inhibit_view_compaction(Bucket, Node, Pid) ->
    gen_fsm:sync_send_all_state_event({?MODULE, Node},
                                      {inhibit_view_compaction, list_to_binary(Bucket), Pid},
                                      infinity).

-spec uninhibit_view_compaction(bucket_name(), node(), reference()) -> ok | nack.
uninhibit_view_compaction(Bucket, Node, Ref) ->
    gen_fsm:sync_send_all_state_event({?MODULE, Node},
                                      {uninhibit_view_compaction, list_to_binary(Bucket), Ref},
                                      infinity).

%% gen_fsm callbacks
init([]) ->
    {ok, idle, []}.

handle_event(Event, StateName, State) ->
    ?log_warning("Got unexpected event ~p (when in ~p):~n~p",
                 [Event, StateName, State]),
    {next_state, StateName, State}.

handle_sync_event(Event, _From, idle, []) ->
    RV = gen_server:call(compaction_new_daemon, Event, infinity),
    {reply, RV, idle, []}.

handle_info(Info, StateName, State) ->
    ?log_warning("Got unexpected message ~p (when in ~p):~n~p",
                 [Info, StateName, State]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.
