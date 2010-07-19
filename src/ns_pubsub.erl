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

-module(ns_pubsub).

-behaviour(gen_event).

-record(state, {func, func_state}).
-record(subscribe_all_state, {noderefs, name, func, func_state}).

-export([code_change/3, init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2]).

-export([subscribe/1, subscribe/3,
         subscribe_all/1, subscribe_all/3,
         unsubscribe/2, unsubscribe_all/1]).


%%
%% API
%%
subscribe(Name) ->
    subscribe(Name, msg_fun(self()), ignored).


subscribe(Name, Fun, State) ->
    Ref = make_ref(),
    ok = gen_event:add_sup_handler(Name, {?MODULE, Ref},
                                   #state{func=Fun, func_state=State}),
    Ref.


%% Subscribe to the same event on all nodes
subscribe_all(Name) ->
    subscribe_all(Name, msg_fun(self()), ignored).


subscribe_all(Name, Fun, State) ->
    Ref = make_ref(),
    ok = gen_event:add_sup_handler(ns_node_disco_events, {?MODULE, Ref},
                                   #subscribe_all_state{noderefs=[], name=Name,
                                                        func=Fun,
                                                        func_state=State}),
    ok = gen_event:call(ns_node_disco_events, {?MODULE, Ref},
                        {init_nodes, ns_node_disco:nodes_actual_proper()}),
    Ref.


unsubscribe(Name, Ref) ->
    gen_event:delete_handler(Name, {?MODULE, Ref}, unsubscribed).


%% We don't need the name for this because it's in the state of the
%% handler installed on ns_node_disco_events
unsubscribe_all(Ref) ->
    gen_event:delete_handler(ns_node_disco_events, {?MODULE, Ref},
                             unsubscribed).


%%
%% gen_event callbacks
%%
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(State) ->
    {ok, State}.

%% Only set initial nodes if we haven't yet received an event
handle_call({init_nodes, Nodes}, State = #subscribe_all_state{noderefs=[]}) ->
    NodeRefs = [{Node, subscribe_node(Node, State)} || Node <- Nodes],
    {ok, ok, State#subscribe_all_state{noderefs=NodeRefs}};
handle_call({init_nodes, _}, State = #subscribe_all_state{noderefs=[_|_]}) ->
    {ok, ok, State}.


handle_event(Event, State = #state{func=Fun, func_state=FS}) ->
    NewState = Fun(Event, FS),
    {ok, State#state{func_state=NewState}};
handle_event({ns_node_disco_events, _OldNodes, Nodes},
             State = #subscribe_all_state{noderefs=NodeRefs}) ->
    NewNodeRefs = [{N, subscribe_node(N, State)} ||
                      N <- Nodes, not lists:keymember(N, 1, NodeRefs)],
    KeepNodeRefs = [NR || NR = {N, _} <- NodeRefs, not lists:member(N, Nodes)],
    {ok, State#subscribe_all_state{noderefs=NewNodeRefs ++ KeepNodeRefs}}.


handle_info(_Msg, State) ->
    {ok, State}.


terminate(_Reason, #subscribe_all_state{noderefs=NodeRefs, name=Name}) ->
    lists:foreach(fun ({Node, Ref}) ->
                          unsubscribe({Name, Node}, Ref)
                  end, NodeRefs);
terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

%% Function sending a message to a pid
msg_fun(Pid) ->
    fun (Event, ignored) ->
            Pid ! Event,
            ignored
    end.


subscribe_node(Node, #subscribe_all_state{name=Name, func=Fun,
                                          func_state=FState}) ->
    subscribe({Name, Node}, Fun, FState).
