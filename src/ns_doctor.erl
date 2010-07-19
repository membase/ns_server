%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_doctor).

-define(STALE_TIME, 5000000). % 5 seconds in microseconds

-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).
%% API
-export([heartbeat/1, get_nodes/0]).

-record(state, {nodes}).

%% gen_server handlers

start_link() ->
    %% If it's already running elsewhere in the cluster, just monitor
    %% the existing process.
    case gen_server:start_link({global, ?MODULE}, ?MODULE, [], []) of
        {error, {already_started, Pid}} ->
            {ok, spawn_link(fun () -> misc:wait_for_process(Pid, infinity) end)};
        X -> X
    end.

init([]) ->
    self() ! acquire_initial_status,
    {ok, #state{nodes=dict:new()}}.

handle_call(get_nodes, _From, State) ->
    Now = erlang:now(),
    Nodes = dict:map(fun (_, Node) ->
                             LastHeard = proplists:get_value(last_heard, Node),
                             case timer:now_diff(Now, LastHeard) > ?STALE_TIME of
                                     true -> [ stale | Node];
                                 false -> Node
                             end
                      end, State#state.nodes),
    {reply, Nodes, State}.

handle_cast({heartbeat, Name, Status}, State) ->
    Nodes = update_status(Name, Status, State#state.nodes),
    {noreply, State#state{nodes=Nodes}}.

handle_info(acquire_initial_status, #state{nodes=NodeDict} = State) ->
    {Replies, BadNodes} = gen_server:multi_call(ns_heart, status),
    case BadNodes of
        [] ->
            ok;
        _ ->
            error_logger:error_msg(
              "~p couldn't contact the following nodes on startup: ~p~n",
              [?MODULE, BadNodes])
    end,
    %% Get an initial status so we don't start up thinking everything's down
    Nodes = lists:foldl(fun ({Node, Status}, Dict) ->
                                update_status(Node, Status, Dict)
                        end, NodeDict, Replies),
    error_logger:info_msg("~p got initial status ~p~n", [?MODULE, Nodes]),
    {noreply, State#state{nodes=Nodes}};
handle_info(Info, State) ->
    error_logger:info_msg("ns_doctor: got unexpected message ~p in state ~p.~n",
                          [Info, State]),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

heartbeat(Status) ->
    heartbeat(node(), Status).

heartbeat(Node, Status) ->
    gen_server:cast({global, ?MODULE}, {heartbeat, Node, Status}).

get_nodes() ->
    try gen_server:call({global, ?MODULE}, get_nodes) of
        Nodes -> Nodes
    catch
        _:_ -> dict:new()
    end.


%% Internal functions

update_status(Name, Status, Dict) ->
    Node = [{last_heard, erlang:now()} | Status],
    dict:store(Name, Node, Dict).
