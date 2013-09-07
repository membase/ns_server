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
%%
%% Provides read_existing_map, which recovers vbucket map from
%% ep-engine persisted vbucket states (i.e. data files).
%%
-module(ns_janitor_map_recoverer).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([read_existing_map/4,
         align_replicas/2]).

-define(CLEAN_VBUCKET_MAP_RECOVER, 0).
-define(UNCLEAN_VBUCKET_MAP_RECOVER, 1).

%% @doc check for existing vbucket states and generate a vbucket map
%% from them
-spec read_existing_map(string(),
                        [atom()],
                        pos_integer(),
                        non_neg_integer()) -> {error, no_map} | {ok, list()}.
read_existing_map(Bucket, S, VBucketsCount, NumReplicas) ->

    VBuckets =
        [begin
             {ok, Buckets} = ns_memcached:list_vbuckets_prevstate(Node, Bucket),
             [{Index, State, Node} || {Index, State} <- Buckets]
         end || Node <- S],


    Fun = fun({Index, active, Node}, {Active, Replica}) ->
                  {[{Index, Node}|Active], Replica};
             ({Index, replica, Node}, {Active, Replica}) ->
                  {Active, dict:append(Index, Node, Replica)};
             (_, Acc) -> % Ignore Dead vbuckets
                  Acc
          end,

    {Active, Replica} =
        lists:foldl(Fun, {[], dict:new()}, lists:flatten(VBuckets)),

    {Map, HasDuplicates} = recover_map(Active, Replica, false, 0,
                                       VBucketsCount, []),
    MissingVBucketsCount = lists:foldl(fun ([undefined|_], Acc) -> Acc+1;
                                           (_, Acc) -> Acc
                                       end, 0, Map),
    case MissingVBucketsCount of
        VBucketsCount -> {error, no_map};
        _ ->
            CleanRecover = MissingVBucketsCount =:= 0
                andalso not HasDuplicates,
            case CleanRecover of
                true ->
                    ?user_log(?CLEAN_VBUCKET_MAP_RECOVER,
                              "Cleanly recovered vbucket map from data files for bucket: ~p~n",
                              [Bucket]);
                _ ->
                    ?user_log(?UNCLEAN_VBUCKET_MAP_RECOVER,
                              "Partially recovered vbucket map from data files for bucket: ~p."
                              ++ " Missing vbuckets count: ~p and HasDuplicates is: ~p~n",
                              [Bucket, MissingVBucketsCount, HasDuplicates])
            end,
            {ok, align_replicas(Map, NumReplicas)}
    end.

-spec recover_map([{non_neg_integer(), node()}],
                  dict(),
                  boolean(),
                  non_neg_integer(),
                  pos_integer(),
                  [[atom()]]) ->
                         {[[atom()]], boolean()}.
recover_map(_Active, _Replica, HasDuplicates, I,
            VBucketsCount, MapAcc) when I >= VBucketsCount ->
    {lists:reverse(MapAcc), HasDuplicates};
recover_map(Active, Replica, HasDuplicates, I, VBucketsCount, MapAcc) ->
    {NewDuplicates, Master} =
        case [N || {Ic, N} <- Active, Ic =:= I] of
            [MasterNode] ->
                {HasDuplicates, MasterNode};
            [] ->
                {HasDuplicates, undefined};
            [MasterNode,_|_] ->
                {true, MasterNode}
        end,
    NewMapAcc = [[Master | case dict:find(I, Replica) of
                               {ok, V} -> V;
                               error -> []
                           end]
                 | MapAcc],
    recover_map(Active, Replica, NewDuplicates, I+1, VBucketsCount, NewMapAcc).

-spec align_replicas([[atom()]], non_neg_integer()) ->
                            [[atom()]].
align_replicas(Map, NumReplicas) ->
    [begin
         [Master | Replicas] = Chain,
         [Master | align_chain_replicas(Replicas, NumReplicas)]
     end || Chain <- Map].

align_chain_replicas(_, 0) -> [];
align_chain_replicas([H|T] = _Chain, ReplicasLeft) ->
    [H | align_chain_replicas(T, ReplicasLeft-1)];
align_chain_replicas([] = _Chain, ReplicasLeft) ->
    lists:duplicate(ReplicasLeft, undefined).

-ifdef(EUNIT).

align_replicas_test() ->
    [[a, b, c],
     [d, e, undefined],
     [undefined, undefined, undefined]] =
        align_replicas([[a, b, c],
                        [d, e],
                        [undefined]], 2),

    [[a, b],
     [d, e],
     [undefined, undefined]] =
        align_replicas([[a, b, c],
                        [d, e],
                        [undefined]], 1),

    [[a],
     [d],
     [undefined]] =
        align_replicas([[a, b, c],
                        [d, e],
                        [undefined]], 0).

recover_map_test() ->
    Result1 = recover_map([{0, a},
                           {2, b},
                           {3, c},
                           {1, e}],
                          dict:from_list([{0, [c, d]},
                                          {1, [d, b]},
                                          {2, [e, d]},
                                          {3, [b, e]}]),
                          false, 0, 4, []),
    {[[a,c,d],
      [e,d,b],
      [b,e,d],
      [c,b,e]], false} = Result1,

    Result2 = recover_map([{0, a},
                           {2, b},
                           {1, e}],
                          dict:from_list([{0, [c, d]},
                                          {1, [d, b]},
                                          {2, [e, d]},
                                          {3, [b, e]}]),
                          false, 0, 4, []),

    {[[a,c,d],
      [e,d,b],
      [b,e,d],
      [undefined,b,e]], false} = Result2,

    Result3 = recover_map([{0, a},
                           {2, b},
                           {2, c},
                           {1, e}],
                          dict:from_list([{0, [c, d]},
                                          {1, [d, b]},
                                          {2, [e, d]},
                                          {3, [b, e]}]),
                          false, 0, 4, []),

    {[[a,c,d],
      [e,d,b],
      [b,e,d],
      [undefined,b,e]], true} = Result3.

-endif.
