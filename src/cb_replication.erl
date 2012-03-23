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

-module(cb_replication).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0,
         get_mode/1,
         supported_mode/0,
         maybe_switch_replication_mode/1]).

-export([add_replica/4,
         kill_replica/4,
         set_replicas/3,
         apply_changes/2,
         stop_replications/4,
         replicas/2,
         node_replicator_triples/2]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {modes}).

%% API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_mode(Bucket) ->
    gen_server:call(?MODULE, {get_mode, Bucket}).

maybe_switch_replication_mode(Bucket) ->
    gen_server:call(?MODULE, {maybe_switch_replication_mode, Bucket}).

add_replica(Bucket, SrcNode, DstNode, VBucket) ->
    kill_all_other_mode_replications(Bucket),
    cb_gen_vbm_sup:add_replica(policy(Bucket),
                               Bucket, SrcNode, DstNode, VBucket).

kill_replica(Bucket, SrcNode, DstNode, VBucket) ->
    cb_gen_vbm_sup:kill_replica(policy_by_mode(new),
                                Bucket, SrcNode, DstNode, VBucket),
    cb_gen_vbm_sup:kill_replica(policy_by_mode(compat),
                                Bucket, SrcNode, DstNode, VBucket).

set_replicas(Bucket, Replicas, AllNodes) ->
    kill_all_other_mode_replications(Bucket),
    cb_gen_vbm_sup:set_replicas(policy(Bucket),
                                Bucket, Replicas, AllNodes).

apply_changes(Bucket, ChangeTuples) ->
    kill_all_other_mode_replications(Bucket),
    cb_gen_vbm_sup:apply_changes(policy(Bucket),
                                 Bucket, ChangeTuples).

stop_replications(Bucket, SrcNode, DstNode, VBuckets) ->
    cb_gen_vbm_sup:stop_replications(policy_by_mode(new),
                                     Bucket, SrcNode, DstNode, VBuckets),
    cb_gen_vbm_sup:stop_replications(policy_by_mode(compat),
                                     Bucket, SrcNode, DstNode, VBuckets).

replicas(Bucket, Nodes) ->
    Mode = supported_mode(),
    cb_gen_vbm_sup:replicas(policy_by_mode(Mode), Bucket, Nodes).

node_replicator_triples(Bucket, Node) ->
    Mode = supported_mode(),
    cb_gen_vbm_sup:node_replicator_triples(policy_by_mode(Mode), Bucket, Node).

supported_mode() ->
    Statuses = ns_doctor:get_nodes(),
    ActiveNodes = ns_cluster_membership:active_nodes(),

    AllNew =
        lists:foldl(
          fun (Node, Ok) ->
                  Ok andalso is_new_status(ns_doctor:get_node(Node, Statuses))
          end, true, ActiveNodes),

    case AllNew of
        true ->
            new;
        false ->
            compat
    end.

%% gen_server callbacks

init([]) ->
    Self = self(),

    ns_pubsub:subscribe_link(
      ns_config_events,
      fun ({buckets, _Buckets} = Ev, _) ->
              Self ! Ev,
              undefined;
          (_, _) ->
              undefined
      end, undefined),

    Buckets = ns_bucket:get_bucket_names(),
    Mode = supported_mode(),
    Modes =
        lists:foldl(
          fun (Bucket, D) ->
                  dict:store(Bucket, Mode, D)
          end, dict:new(), Buckets),

    {ok, #state{modes=Modes}}.

handle_call({get_mode, Bucket}, _From,
            #state{modes=Modes} = State) ->
    Mode = case dict:find(Bucket, Modes) of
               {ok, Value} ->
                   Value;
               error ->
                   %% this should only happen when master node was failed over
                   %% when it was still alive; in such a case we would have
                   %% already got a bucket deletion notification; hence there
                   %% would not be an entry in mode dictionary
                   ?log_info("Didn't find current "
                             "replication mode for bucket ~p", [Bucket]),
                   supported_mode()
           end,

    {reply, Mode, State};
handle_call({maybe_switch_replication_mode, Bucket}, _From,
            #state{modes=Modes} = State) ->
    NewMode = supported_mode(),

    Modes1 =
        dict:update(
          Bucket,
          fun (OldMode) ->
                  case OldMode =:= NewMode of
                      true ->
                          ok;
                      false ->
                          ?log_info("Switching replication mode for ~s "
                                    "from ~p to ~p", [Bucket, OldMode, NewMode])
                  end,
                  NewMode
          end, NewMode, Modes),

    {reply, ok, State#state{modes=Modes1}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({buckets, RawBuckets}, #state{modes=Modes} = State) ->
    CurrentBuckets = dict:fetch_keys(Modes),
    Configs = proplists:get_value(configs, RawBuckets, []),
    Buckets = ns_bucket:node_bucket_names(node(), Configs),

    New = Buckets -- CurrentBuckets,
    Deleted = CurrentBuckets -- Buckets,

    Mode = supported_mode(),

    Modes1 =
        lists:foldl(
          fun (Bucket, D) ->
                  dict:store(Bucket, Mode, D)
          end, Modes, New),

    Modes2 =
        lists:foldl(
          fun (Bucket, D) ->
                  dict:erase(Bucket, D)
          end, Modes1, Deleted),

    {noreply, State#state{modes=Modes2}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra)->
    {ok, State}.

%% Internal functions
policy_by_mode(new) ->
    ns_vbm_new_sup;
policy_by_mode(compat) ->
    ns_vbm_sup.

flip_mode(new) ->
    compat;
flip_mode(compat) ->
    new.

kill_all_other_mode_replications(Bucket) ->
    Mode = flip_mode(get_mode(Bucket)),
    Policy = policy_by_mode(Mode),

    Nodes = ns_node_disco:nodes_actual_proper(),
    cb_gen_vbm_sup:kill_all_children(Policy, Bucket, Nodes).

policy(Bucket) ->
    policy_by_mode(get_mode(Bucket)).

is_new_status(NodeStatus) ->
    undefined =/=
        proplists:get_value(outgoing_replications_safeness_level, NodeStatus).
