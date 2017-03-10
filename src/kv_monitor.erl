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

-module(kv_monitor).

-include("ns_common.hrl").

-export([start_link/0]).
-export([get_nodes/0,
         analyze_status/2,
         is_node_down/1]).

-export([init/0, handle_call/4, handle_cast/3, handle_info/3]).

-define(NS_MEMCACHED_TIMEOUT, 500).

start_link() ->
    health_monitor:start_link(?MODULE).

%% gen_server callbacks
init() ->
    health_monitor:common_init(?MODULE, with_refresh).

handle_call(get_nodes, _From, Statuses, _Nodes) ->
    {reply, Statuses};

handle_call(Call, From, Statuses, _Nodes) ->
    ?log_warning("Unexpected call ~p from ~p when in state:~n~p",
                 [Call, From, Statuses]),
    {reply, nack}.

handle_cast(Cast, Statuses, _Nodes) ->
    ?log_warning("Unexpected cast ~p when in state:~n~p", [Cast, Statuses]),
    noreply.

handle_info(refresh, _Statuses, NodesWanted) ->
    {noreply, handle_refresh_status(NodesWanted)};

handle_info(Info, Statuses, _Nodes) ->
    ?log_warning("Unexpected message ~p when in state:~n~p", [Info, Statuses]),
    noreply.

%% APIs
get_nodes() ->
    gen_server:call(?MODULE, get_nodes).

analyze_status(Node, AllNodes) ->
    Buckets = ns_bucket:node_bucket_names(Node),

    %% Initially, all buckets are considered not ready.
    case get_not_ready_buckets(AllNodes, Node, Buckets) of
        [] ->
            %% All buckets are active or ready
            healthy;
        Buckets ->
            %% None of the buckets are active or ready
            unhealthy;
        NotReadyBuckets ->
            {not_ready, NotReadyBuckets}
    end.

is_node_down(needs_attention) ->
    {true, {"The data service did not respond for the duration of the auto-failover threshold. Either none of the buckets have warmed up or there is an issue with the data service.", no_buckets_ready}};
is_node_down({not_ready, Buckets}) ->
    {true, {"The data service is online but the following buckets' data are not accessible: " ++ string:join(Buckets, ", ") ++ ".", some_buckets_not_ready}}.

%% Internal functions
get_not_ready_buckets(_, _, []) ->
    [];
get_not_ready_buckets([], _, NotReadyBuckets) ->
    NotReadyBuckets;
get_not_ready_buckets([{_OtherNode, inactive, _} | Rest], Node,
                      NotReadyBuckets) ->
    %% Consider OtherNode's view  only if it itself is active.
    get_not_ready_buckets(Rest, Node, NotReadyBuckets);
get_not_ready_buckets([{_OtherNode, _, OtherNodeView} | Rest], Node,
                      NotReadyBuckets) ->
    NodeStatus = proplists:get_value(Node, OtherNodeView, []),
    case proplists:get_value(kv, NodeStatus, unknown) of
        unknown ->
            get_not_ready_buckets(Rest, Node, NotReadyBuckets);
        [] ->
            get_not_ready_buckets(Rest, Node, NotReadyBuckets);
        BucketList ->
            %% Remove active/ready buckets from NotReadyBuckets list.
            NotReady = lists:filter(
                         fun (Bucket) ->
                                 case lists:keyfind(Bucket, 1, BucketList) of
                                     false ->
                                         true;
                                     {Bucket, active} ->
                                         false;
                                     {Bucket, ready} ->
                                         false;
                                     _ ->
                                         true
                                 end
                         end, NotReadyBuckets),
            get_not_ready_buckets(Rest, Node, NotReady)
    end.

handle_refresh_status(NodesWanted) ->
    NodesDict = get_dcp_traffic_status(),

    %% To most part, the nodes returned by DCP traffic monitor will
    %% be the same or subset of the ones in the KV monitor. But, the two
    %% monitors might get out-of-sync for short duration during the
    %% the nodes_wanted change. If the DCP traffic monitor returns
    %% a node unknown to the KV monitor then ignore it.
    Statuses = erase_unknown_nodes(NodesDict, NodesWanted),

    maybe_add_local_node(Statuses).

get_dcp_traffic_status() ->
    dict:map(
      fun (_Node, Buckets) ->
              lists:map(
                fun ({Bucket, LastHeard}) ->
                        {Bucket, health_monitor:is_active(LastHeard)}
                end, Buckets)
      end, dcp_traffic_monitor:get_nodes()).

erase_unknown_nodes(NodesDict, Nodes) ->
    {Statuses, _} = health_monitor:process_nodes_wanted(NodesDict, Nodes),
    Statuses.

maybe_add_local_node(Statuses) ->
    case dict:find(node(), Statuses) of
        {ok, Buckets} ->
            %% Some buckets may not have DCP streams.
            %% Find their status from ns_memcached:warmed_buckets().
            %% This list of buckets is from dcp_traffic_monitor and may not
            %% be in sorted order.
            Buckets1 = lists:keysort(1, Buckets),
            case local_node_status(Buckets1) of
                Buckets1 ->
                    Statuses;
                NewBuckets ->
                    dict:store(node(), NewBuckets, Statuses)
            end;
        error ->
            %% No DCP streams for any bucket on the node.
            %% Find bucket status from ns_memcached:warmed_buckets().
            dict:store(node(), local_node_status([]), Statuses)
    end.

local_node_status(Buckets) ->
    ExpectedBuckets = ns_bucket:node_bucket_names(node()),
    ActiveBuckets = [Bucket || {Bucket, active} <- Buckets],
    case ExpectedBuckets -- ActiveBuckets of
        [] ->
            Buckets;
        GetBuckets ->
            MoreBuckets = lists:keysort(1, get_buckets(GetBuckets)),
            %% It is possible to have duplicate entries in MoreBuckets
            %% and Buckets. E.g. an "inactive" bucket in Buckets.
            %% In such a case, we pick from MoreBuckets.
            misc:ukeymergewith(fun (New, _Old) -> New end, 1,
                               MoreBuckets, Buckets)
    end.

get_buckets(Buckets) ->
    ReadyBuckets = try ns_memcached:warmed_buckets(?NS_MEMCACHED_TIMEOUT)
                   catch exit:{timeout, _} ->
                           ?log_warning("ns_memcached:warmed_buckets timed out while trying to get buckets: ~p", [Buckets]),
                           []
                   end,
    lists:map(
      fun (Bucket) ->
              State = case lists:member(Bucket, ReadyBuckets) of
                          true ->
                              ready;
                          false ->
                              not_ready
                      end,
              {Bucket, State}
      end, Buckets).
