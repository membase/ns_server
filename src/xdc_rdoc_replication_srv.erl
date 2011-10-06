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
%%
-module(xdc_rdoc_replication_srv).

-behaviour(gen_server).

-include("ns_common.hrl").
-include("couch_db.hrl").
-include("couch_replicator.hrl").

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {nodes = []}).

-compile(export_all).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

init([]) ->
    erlang:process_flag(trap_exit, true),

    ns_pubsub:subscribe(ns_config_events),
    {ok, start_replication(#state{})}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodes_wanted, NodesWanted}, State) ->
    Nodes = NodesWanted -- [node()],
    NewState = State#state{nodes=Nodes},
    {noreply, update(NewState, NodesWanted)};
handle_info({'DOWN', _Ref, process, _Pid, Reason}, State)
  when Reason =:= normal orelse Reason =:= shutdown ->
    {noreply, State};
handle_info({'DOWN', _Ref, process, _Pid, Reason}, State) ->
    ?log_info("Replication slave crashed with reason: ~p", [Reason]),
    {noreply, start_replication(State)};
handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    stop_replication(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

update(#state{nodes=Nodes} = State, NewNodes) ->
    {ToStart, ToStop} = difference(Nodes, NewNodes),

    lists:foreach(fun stop_server_replication/1, ToStop),
    lists:foreach(fun start_server_replication/1, ToStart),

    State#state{nodes=NewNodes}.

difference(List1, List2) ->
    {List2 -- List1, List1 -- List2}.

build_replication_struct(Source, Target) ->
    {ok, Replication} =
        couch_replicator_utils:parse_rep_doc(
          {[{<<"source">>, Source},
            {<<"target">>, Target}
            | default_opts()]},
          #user_ctx{roles = [<<"_admin">>]}),
    Replication.

start_replication(State) ->
    Nodes = ns_node_disco:nodes_wanted() -- [node()],
    start_replication(State, Nodes).

start_replication(State, Nodes) ->
    lists:foreach(fun start_server_replication/1, Nodes),
    State#state{nodes=Nodes}.

stop_replication(State) ->
    Nodes = ns_node_disco:nodes_wanted() -- [node()],
    stop_replication(State, Nodes).

stop_replication(State, Nodes) ->
    lists:foreach(fun stop_server_replication/1, Nodes),
    State#state{nodes=[]}.

start_server_replication(Node) ->
    Opts = build_replication_struct(remote_url(Node), <<"_replicator">>),
    {ok, Pid} = couch_replicator:async_replicate(Opts),
    erlang:monitor(process, Pid),
    ok.

stop_server_replication(Node) ->
    Opts = build_replication_struct(remote_url(Node), <<"_replicator">>),
    {ok, _Res} = couch_replicator:cancel_replication(Opts#rep.id).

remote_url(Node) ->
    Url = capi_utils:capi_url(Node, "/_replicator", "127.0.0.1"),
    ?l2b(Url).

default_opts() ->
    [{<<"continuous">>, true},
     {<<"worker_processes">>, 1},
     {<<"http_connections">>, 10}
    ].
