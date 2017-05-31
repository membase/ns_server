%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
%% @doc - This module contains the logic to reprovision a bucket when
%% the active vbuckets are found to be in "missing" state. Typically,
%% such a scenario would arise in case of ephemeral buckets when the
%% memcached process on a node restarts within the auto-failover
%% timeout.
-module(auto_reprovision).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start_link/0]).

%% APIs.
-export([
         enable/1,
         disable/0,
         reset_count/0,
         reprovision_buckets/2,
         get_cleanup_options/0
        ]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_MAX_NODES_SUPPORTED, 1).

-record(state, {enabled = false :: boolean(),
                max_nodes = ?DEFAULT_MAX_NODES_SUPPORTED :: integer(),
                count = 0 :: integer()}).

start_link() ->
    misc:start_singleton(gen_server, ?MODULE, [], []).

%% APIs.
-spec enable(integer()) -> ok.
enable(MaxNodes) ->
    call({enable, MaxNodes}).

-spec disable() -> ok.
disable() ->
    call(disable).

-spec reset_count() -> ok.
reset_count() ->
    call(reset_count).

-spec reprovision_buckets([bucket_name()], [node()]) -> ok | {error, term()}.
reprovision_buckets([], _UnsafeNodes) ->
    ok;
reprovision_buckets(Buckets, UnsafeNodes) ->
    call({reprovision_buckets, Buckets, UnsafeNodes}).

-spec get_cleanup_options() -> [term()].
get_cleanup_options() ->
    call(get_cleanup_options).

call(Msg) ->
    misc:wait_for_global_name(?MODULE),
    gen_server:call({global, ?MODULE}, Msg, 5000).

%% gen_server callbacks.
init([]) ->
    {Enabled, MaxNodes, Count} = get_reprovision_cfg(),
    {ok, #state{enabled = Enabled, max_nodes = MaxNodes, count = Count}}.

handle_call({enable, MaxNodes}, _From, #state{count = Count} = State) ->
    ale:info(?USER_LOGGER, "Enabled auto-reprovision config with max_nodes set to ~p", [MaxNodes]),
    ok = persist_config(true, MaxNodes, Count),
    {reply, ok, State#state{enabled = true, max_nodes = MaxNodes, count = Count}};
handle_call(disable, _From, _State) ->
    ok = persist_config(false, ?DEFAULT_MAX_NODES_SUPPORTED, 0),
    {reply, ok, #state{}};
handle_call(reset_count, _From, #state{count = 0} = State) ->
    {reply, ok, State};
handle_call(reset_count, _From, State) ->
    {Enabled, MaxNodes, Count} = get_reprovision_cfg(),
    ale:info(?USER_LOGGER, "auto-reprovision count reset from ~p", [Count]),
    ok = persist_config(Enabled, MaxNodes, 0),
    {reply, ok, State#state{count = 0}};
handle_call({reprovision_buckets, Buckets, UnsafeNodes}, _From,
            #state{enabled = Enabled, max_nodes = MaxNodes, count = Count} = State) ->
    RCount = MaxNodes - Count,
    Candidates = lists:sublist(UnsafeNodes, RCount),
    NewCount = Count + length(Candidates),

    %% As part of auto-reprovision operation, we mend the maps of all the
    %% affected buckets and update the ns_config along with the adjusted
    %% auto-reprovision count as part of a single transaction. The updated
    %% buckets will be brought online as part of the next janitor cleanup.
    TxnRV = ns_config:run_txn(
              fun(Cfg, SetFn) ->
                      %% Update the bucket configs with reprovisioned data.
                      NewBConfigs =
                          lists:foldl(
                            fun(Bucket, Acc) ->
                                    {ok, BCfg} = ns_bucket:get_bucket(Bucket, Cfg),
                                    NewBCfg = do_reprovision_bucket(Bucket, BCfg, UnsafeNodes,
                                                                    Candidates),
                                    lists:keyreplace(Bucket, 1, Acc, {Bucket, NewBCfg})
                            end, ns_bucket:get_buckets(Cfg), Buckets),

                      {value, BucketsKV} = ns_config:search(Cfg, buckets),
                      NewBucketsKV = lists:keyreplace(configs, 1, BucketsKV,
                                                      {configs, NewBConfigs}),

                      %% Update the count in auto_reprovision_cfg.
                      RCfg = [{enabled, Enabled}, {max_nodes, MaxNodes}, {count, NewCount}],

                      case NewCount >= MaxNodes of
                          true ->
                              ale:info(?USER_LOGGER, "auto-reprovision is disabled as maximum "
                                       "number of nodes (~p) that can be auto-reprovisioned has "
                                       "been reached.", [MaxNodes]);
                          false ->
                              ok
                      end,

                      %% Add both the updates to the transaction.
                      NewCfg = SetFn(buckets, NewBucketsKV, Cfg),
                      {commit, SetFn(auto_reprovision_cfg, RCfg, NewCfg)}
              end),

    {RV, State1} = case TxnRV of
                       {commit, _} -> {ok, State#state{count = NewCount}};
                       {abort, Error} -> {Error, State};
                       _ -> {{error, reprovision_failed}, State}
                   end,
    {reply, RV, State1};

handle_call(get_cleanup_options, _From,
            #state{enabled = Enabled, max_nodes = MaxNodes, count = Count} = State) ->
    {reply, [{check_for_unsafe_nodes, Enabled =:= true andalso Count < MaxNodes}], State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions.
persist_config(Enabled, MaxNodes, Count) ->
    ns_config:set(auto_reprovision_cfg,
                  [{enabled, Enabled},
                   {max_nodes, MaxNodes},
                   {count, Count}]).

get_reprovision_cfg() ->
    {value, RCfg} = ns_config:search(ns_config:latest(), auto_reprovision_cfg),
    {proplists:get_value(enabled, RCfg, true),
     proplists:get_value(max_nodes, RCfg, ?DEFAULT_MAX_NODES_SUPPORTED),
     proplists:get_value(count, RCfg, 0)}.

do_reprovision_bucket(Bucket, BucketConfig, UnsafeNodes, Candidates) ->
    %% Since this will be called by the orchestrator immediately after the cleanup (map
    %% fixup would have happened as part of cleanup) we are just reusing the map in the
    %% bucket config.
    Map = proplists:get_value(map, BucketConfig, []),
    true = (Map =/= []),

    NewMap = [promote_replica(Chain, Candidates) || Chain <- Map],

    ale:info(?USER_LOGGER,
             "Bucket ~p has been reprovisioned on following nodes: ~p. "
             "Nodes on which the data service restarted: ~p.",
             [Bucket, Candidates, UnsafeNodes]),

    lists:keyreplace(map, 1, BucketConfig, {map, NewMap}).

promote_replica([Master | _] = Chain, Candidates) ->
    case lists:member(Master, Candidates) of
        true ->
            NewChain = mb_map:promote_replica(Chain, [Master]),
            promote_replica(NewChain, Candidates);
        false ->
            Chain
    end.
