%% @author Couchbase <info@couchbase.com>
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

-module(tap_replication_manager).

-behavior(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_info/2, terminate/2, code_change/3]).
-export([handle_cast/2]).

-export([get_actual_replications/1,
         start_replication/3, kill_replication/3, modify_replication/4]).


-include("ns_common.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(state, {bucket_name :: bucket_name(),
                not_readys_per_node_ets :: ets:tid(),
                desired_replications :: [{node(), [vbucket_id()]}]
               }).


start_link(Bucket) ->
    proc_lib:start_link(?MODULE, init, [Bucket]).

server_name(Bucket) ->
    list_to_atom("tap_replication_manager-" ++ Bucket).

init(Bucket) ->
    T = ets:new(a, [set, private]),

    erlang:register(server_name(Bucket), self()),
    proc_lib:init_ack({ok, self()}),

    gen_server:enter_loop(?MODULE, [],
                          #state{bucket_name = Bucket,
                                 not_readys_per_node_ets = T,
                                 desired_replications = []}).

start_replication(Bucket, SrcNode, VBuckets) ->
    gen_server:call(server_name(Bucket), {start_child, SrcNode, VBuckets}, infinity).

kill_replication(Bucket, SrcNode, VBuckets) ->
    gen_server:call(server_name(Bucket), {kill_child, SrcNode, VBuckets}, infinity).

modify_replication(Bucket, SrcNode, OldVBuckets, NewVBuckets) ->
    gen_server:call(server_name(Bucket),
                    {change_vbucket_filter, SrcNode, OldVBuckets, NewVBuckets}, infinity).

-spec get_actual_replications(Bucket::bucket_name()) ->
                                     not_running |
                                     [{Node::node(), [non_neg_integer()]}].
get_actual_replications(Bucket) ->
    case ns_vbm_sup:get_children(Bucket) of
        not_running -> not_running;
        Kids ->
            lists:sort([{_Node, _VBuckets} = childs_node_and_vbuckets(Child) || Child <- Kids])
    end.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_call({start_child, SrcNode, VBuckets}, _From,
            #state{desired_replications = Repl} = State) ->
    NewRepl = lists:keystore(SrcNode, 1, Repl, {SrcNode, VBuckets}),
    {reply, do_start_child(State, SrcNode, VBuckets), State#state{desired_replications = NewRepl}};
handle_call({kill_child, SrcNode, VBuckets}, _From,
           #state{desired_replications = Repl} = State) ->
    NewRepl = lists:keydelete(SrcNode, 1, Repl),
    {reply, do_kill_child(State, SrcNode, VBuckets), State#state{desired_replications = NewRepl}};
handle_call({change_vbucket_filter, SrcNode, OldVBuckets, NewVBuckets}, _From,
            #state{desired_replications = Repl} = State) ->
    NewRepl = lists:keystore(SrcNode, 1, Repl, {SrcNode, NewVBuckets}),
    {reply, do_change_vbucket_filter(State, SrcNode, OldVBuckets, NewVBuckets),
     State#state{desired_replications = NewRepl}}.

handle_info({have_not_ready_vbuckets, Node}, #state{not_readys_per_node_ets = T} = State) ->
    {ok, TRef} = timer2:send_after(30000, {restart_replicator, Node}),
    ets:insert(T, {Node, TRef}),
    {noreply, State};
handle_info({restart_replicator, Node}, State) ->
    {Node, VBuckets} = lists:keyfind(Node, 1, State#state.desired_replications),
    ?log_info("Restarting replicator that had not_ready_vbuckets: ~p", [{Node, VBuckets}]),
    ets:delete(State#state.not_readys_per_node_ets, Node),
    do_kill_child(State, Node, VBuckets),
    do_start_child(State, Node, VBuckets),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

cancel_replicator_reset(T, SrcNode) ->
    case ets:lookup(T, SrcNode) of
        [] ->
            ok;
        [{SrcNode, TRef}] ->
            timer2:cancel(TRef),
            ets:delete(T, SrcNode)
    end.


do_start_child(#state{bucket_name = Bucket,
                      not_readys_per_node_ets = T},
               SrcNode, VBuckets) ->
    ?log_info("Starting replication from ~p for~n~p", [SrcNode, VBuckets]),
    [] = _MaybeSameSrcNode = [Child || Child <- ns_vbm_sup:get_children(Bucket),
                                       {SrcNodeC, _} <- [childs_node_and_vbuckets(Child)],
                                       SrcNodeC =:= SrcNode],
    Sup = ns_vbm_sup:server_name(Bucket),
    Child = ns_vbm_sup:make_replicator(SrcNode, VBuckets),
    ChildSpec = child_to_supervisor_spec(Bucket, Child),
    cancel_replicator_reset(T, SrcNode),
    case supervisor:start_child(Sup, ChildSpec) of
        {ok, _} = R -> R;
        {ok, _, _} = R -> R
    end.

do_kill_child(#state{bucket_name = Bucket,
                     not_readys_per_node_ets = T},
              SrcNode, VBuckets) ->
    ?log_info("Going to stop replication from ~p", [SrcNode]),
    Sup = ns_vbm_sup:server_name(Bucket),
    Child = ns_vbm_sup:make_replicator(SrcNode, VBuckets),
    cancel_replicator_reset(T, SrcNode),
    %% we're ok if child is already dead. There's not much we can or
    %% should do about that
    _ = supervisor:terminate_child(Sup, Child).

do_change_vbucket_filter(#state{bucket_name = Bucket,
                                not_readys_per_node_ets = T} = State,
                         SrcNode, OldVBuckets, NewVBuckets) ->
    %% TODO: potential slowness here. Consider ordsets
    ?log_info("Going to change replication from ~p to have~n~p (~p, ~p)",
              [SrcNode, NewVBuckets, NewVBuckets--OldVBuckets, OldVBuckets--NewVBuckets]),
    OldChildId = ns_vbm_sup:make_replicator(SrcNode, OldVBuckets),
    NewChildId = ns_vbm_sup:make_replicator(SrcNode, NewVBuckets),
    Args = build_replicator_args(Bucket, SrcNode, NewVBuckets),

    MFA = {ebucketmigrator_srv, start_vbucket_filter_change, [NewVBuckets]},

    cancel_replicator_reset(T, SrcNode),
    try ns_vbm_sup:perform_vbucket_filter_change(Bucket,
                                                     OldChildId,
                                                     NewChildId,
                                                     Args,
                                                     MFA,
                                                     ns_vbm_sup:server_name(Bucket)) of
        RV -> {ok, RV}
    catch error:upstream_conn_is_down ->
            ?log_debug("Detected upstream_conn_is_down and going to simply start fresh ebucketmigrator"),
            do_start_child(State, SrcNode, NewVBuckets),
            {ok, ok}
    end.

childs_node_and_vbuckets(Child) ->
    {Node, _} = ns_vbm_sup:replicator_nodes(node(), Child),
    VBs = ns_vbm_sup:replicator_vbuckets(Child),
    {Node, VBs}.

child_to_supervisor_spec(Bucket, Child) ->
    {SrcNode, VBuckets} = childs_node_and_vbuckets(Child),
    Args = build_replicator_args(Bucket, SrcNode, VBuckets),
    ns_vbm_sup:build_child_spec(Child, Args).

build_replicator_args(Bucket, SrcNode, VBuckets) ->
    Args = ebucketmigrator_srv:build_args(node(), Bucket,
                                          SrcNode, node(),
                                          VBuckets, false),
    Self = self(),
    ebucketmigrator_srv:add_args_option(Args, on_not_ready_vbuckets,
                                        fun () -> handle_not_ready_vbuckets_from(Self, SrcNode) end).

handle_not_ready_vbuckets_from(RepManagerPid, SrcNode) ->
    RepManagerPid ! {have_not_ready_vbuckets, SrcNode}.
