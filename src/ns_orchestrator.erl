%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Monitor and maintain the vbucket layout of each bucket.
%% There is one of these per bucket.

%% The goal is to keep the orchestrator as stateless as possible
%% so it can crash with impunity.

%% States: initializing, idle, rebalancing

-module(ns_orchestrator).

-behaviour(gen_server).

%% Constants and definitions

-define(INTERVAL, 5000).

-record(state, {bucket, map}).

%% API
-export([start_link/1]).

-export([get_json_map/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

%% API
start_link(Bucket) ->
    gen_server:start_link(server(Bucket), ?MODULE, Bucket, []).

get_json_map(BucketId) ->
    Config = ns_config:get(),
    Buckets = ns_config:search_node_prop(Config, memcached, buckets),
    BucketConfig = proplists:get_value(BucketId, Buckets),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),
    NumReplicas = proplists:get_value(num_replicas, BucketConfig),
    ENodes = lists:sort(ns_node_disco:nodes_wanted()),
    Port = ns_config:search_node_prop(Config, memcached, port),
    PortStr = integer_to_list(Port),
    Servers = lists:map(fun (ENode) ->
                                {_Name, Host} = misc:node_name_host(ENode),
                                list_to_binary(Host ++ ":" ++ PortStr)
                        end, ENodes),
    VBMap = case proplists:get_value(map, BucketConfig) of
                undefined ->
                    lists:duplicate(NumVBuckets,
                                    lists:duplicate(NumReplicas + 1, undefined));
                M -> M
            end,
    Map = lists:map(fun (VBucket) ->
                            lists:map(fun (undefined) -> -1;
                                          (ENode) -> misc:position(ENode, ENodes) - 1
                                      end, VBucket)
                    end, VBMap),
    {struct, [{hashAlgorithm, <<"CRC">>},
              {numReplicas, NumReplicas},
              {serverList, Servers},
              {vBucketMap, Map}]}.


%% gen_server callbacks
init(Bucket) ->
    {ok, _} = timer:send_interval(?INTERVAL, check),
    {ok, #state{bucket=Bucket}}.

handle_call(get_map, _From, State = #state{map = Map}) ->
    {reply, Map, State};
handle_call(Request, From, State) ->
    error_logger:info_msg("~p:handle_call(~p, ~p, ~p)~n",
                          [?MODULE, Request, From, State]),
    {reply, {unhandled, ?MODULE, Request}, State}.

handle_cast(Msg, State) ->
    error_logger:info_msg("~p:handle_cast(~p, ~p)~n",
                          [?MODULE, Msg, State]),
    {noreply, State}.

handle_info(check, State) ->
    NewState = check(State),
    {noreply, NewState};
handle_info(Msg, State) ->
    error_logger:info_msg("~p:handle_info(~p, ~p)~n",
                          [?MODULE, Msg, State]),
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions

%% Count of buckets at each position in the replication chain for each server
adopt([], _Histogram, Adoptions) -> Adoptions;
adopt([Orphan|Rest], Histogram, Adoptions) ->
    [{Server, N}|Servers] = lists:keysort(2, Histogram),
    adopt(Rest, [{Server, N+1}|Servers], [{Orphan, Server}|Adoptions]).

adopt_orphans(State = #state{bucket = Bucket}, Map, NumReplicas, Servers) ->
    Histograms = histogram(Map, NumReplicas, Servers),
    [MasterHistogram|_ReplicaHistograms] = Histograms,
    case lists:map(fun ({N, _}) -> N end,
                   lists:filter(fun ({_, [undefined|_]}) -> true;
                                    (_) -> false
                                end, misc:enumerate(Map, 0))) of
        [] ->
            set_map(State, Map);
        MasterOrphans ->
            Assignments = adopt(MasterOrphans, dict:to_list(MasterHistogram), []),
            lists:foreach(fun ({VBucketId, Master}) ->
                                  ns_memcached:set_vbucket_state(Master, Bucket, VBucketId, active)
                          end, Assignments),
            self() ! check,
            State
    end.

check(State = #state{bucket=Bucket}) ->
    {CurrentStates, Servers, Zombies} = current_states(Bucket),
    case Zombies of
        [] -> migrate(State, CurrentStates, Servers);
        _ -> error_logger:error_msg("~p:check(~p): Eek! Zombies! ~p~n",
                                    [?MODULE, State, Zombies]),
             State
    end.

config(Bucket) ->
    {ok, CurrentConfig} = ns_bucket:get_bucket(Bucket),
    NumReplicas = proplists:get_value(num_replicas, CurrentConfig),
    NumVBuckets = proplists:get_value(num_vbuckets, CurrentConfig),
    Map = case proplists:get_value(map, CurrentConfig) of
              undefined ->
                  lists:duplicate(NumVBuckets, lists:duplicate(NumReplicas+1, undefined));
              M -> M
          end,
    {NumReplicas, NumVBuckets, Map}.


current_states(Bucket) ->
    NodesWanted = ns_node_disco:nodes_wanted(),
    AliveNodes = ns_node_disco:nodes_actual_proper(),
    DeadNodes = lists:filter(fun (Node) -> not lists:member(Node, AliveNodes) end,
                             NodesWanted),
    {Replies, BadNodes} = ns_memcached:list_vbuckets_multi(AliveNodes, Bucket),
    {GoodReplies, BadReplies} = lists:splitwith(fun ({_, {ok, _}}) -> true;
                                                    (_) -> false
                                                end, Replies),
    ErrorNodes = [Node || {Node, _} <- BadReplies],
    StateDict = lists:foldl(fun vbucket_states/2, dict:new(), GoodReplies),
    {StateDict, AliveNodes, BadNodes ++ DeadNodes ++ ErrorNodes}.

histogram(Map, NumReplicas, Servers) ->
    DefaultDict = dict:from_list(lists:map(fun (Server) -> {Server, 0} end, Servers)),
    lists:map(
      fun (Position) ->
              lists:foldl(
                fun (L, D) ->
                        case lists:nth(Position, L) of
                            undefined -> D;
                            Server ->
                                dict:update(Server, fun (N) -> N + 1 end, 1, D)
                        end
                end, DefaultDict, Map)
      end, lists:seq(1, NumReplicas + 1)).

map(StateDict, NumReplicas, NumVBuckets) ->
    lists:map(fun (VBucketId) ->
                      States = case dict:find(VBucketId, StateDict) of
                                   {ok, List} -> List;
                                   error -> []
                               end,
                      ActiveServers = misc:mapfilter(fun ({Server, active}) -> Server;
                                                         ({_Server, _}) -> false
                                                     end, false, States),
                      Master = case ActiveServers of
                                   [M] -> M;
                                   [] -> undefined;
                                   _ -> conflict
                               end,
                      [Master|lists:duplicate(NumReplicas, undefined)]
              end, lists:seq(0, NumVBuckets-1)).



migrate(State = #state{bucket=Bucket}, CurrentStates, Servers) ->
    {NumReplicas, NumVBuckets, _ConfigMap} = config(Bucket),
    Map = map(CurrentStates, NumReplicas, NumVBuckets),
    adopt_orphans(State, Map, NumReplicas, Servers).

server(Bucket) ->
    {global, list_to_atom(lists:flatten(io_lib:format("~s-~s", [?MODULE, Bucket])))}.

set_map(State = #state{map = OldMap}, Map) when Map == OldMap ->
    State;
set_map(State = #state{bucket = Bucket}, Map) ->
    ns_bucket:set_map(Bucket, Map),
    State#state{map = Map}.

vbucket_states({Node, {ok, Reply}}, Dict) ->
    lists:foldl(fun ({VBucket, State}, D) ->
                        dict:update(VBucket,
                                    fun (L) -> [{Node, State}|L] end,
                                    [{Node, State}], D)
                end, Dict, Reply).

