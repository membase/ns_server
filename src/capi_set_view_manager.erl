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

-module(capi_set_view_manager).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

%% API
-export([start_link/1]).

%% debug
-export([get_state/1]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").
-include("ns_common.hrl").

-record(state, {bucket,
                bucket_config,
                vbucket_states,
                master_db_watcher,
                map}).

start_link(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            ignore;
        _ ->
            gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, [])
    end.

get_state(Bucket) ->
    gen_server:call(server(Bucket), get_state).

init(Bucket) ->
    process_flag(trap_exit, true),

    ns_pubsub:subscribe(ns_config_events,
                        mk_filter(fun interesting_ns_config_event/1), ignored),
    ns_pubsub:subscribe(mc_couch_events,
                        mk_filter(fun interesting_mc_couch_event/1), ignored),

    Self = self(),
    Watcher =
        spawn_link(
          fun () ->
                  master_db_watcher(Bucket, Self)
          end),

    State = #state{bucket=Bucket,
                   master_db_watcher=Watcher},

    {ok, apply_current_map(State)}.

handle_call(get_state, _From, State) ->
    {reply, State, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({update_ddoc, DDocId},
            #state{bucket=Bucket,
                   bucket_config=BucketConfig, map=Map} = State) ->
    maybe_define_group(Bucket, BucketConfig, DDocId, Map),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({buckets, Buckets},
            #state{bucket=Bucket, map=Map,
                   vbucket_states=VBucketStates} = State) ->
    ?log_debug("Got `buckets` event"),

    BucketConfigs = proplists:get_value(configs, Buckets),
    BucketConfig = proplists:get_value(Bucket, BucketConfigs),

    NewMap = build_map(BucketConfig, VBucketStates),

    NewState =
        case NewMap =/= Map of
            true ->
                apply_map(Bucket, BucketConfig, Map, NewMap),
                State#state{bucket_config=BucketConfig, map=NewMap};
            false ->
                State#state{bucket_config=BucketConfig}
        end,

    {noreply, NewState};

handle_info({set_vbucket, Bucket, VBucket, _VBucketState, _CheckpointId},
            #state{bucket=Bucket, bucket_config=BucketConfig, map=Map,
                   vbucket_states=OldStates} = State) ->
    VBucketState = get_vbucket_state(Bucket, VBucket),

    ?log_debug("Got set_vbucket event for ~s/~b. Updated state: ~p",
               [Bucket, VBucket, VBucketState]),

    NewStates = dict:store(VBucket, VBucketState, OldStates),
    NewMap = build_map(BucketConfig, NewStates),
    NewState =
        case NewMap =/= Map of
            true ->
                apply_map(Bucket, BucketConfig, Map, NewMap),
                State#state{vbucket_states=NewStates, map=NewMap};
            false ->
                State#state{vbucket_states=NewStates}
        end,

    {noreply, NewState};

handle_info({flush_all, Bucket}, #state{bucket=Bucket} = State) ->
    {noreply, apply_current_map(State)};

handle_info({'EXIT', Pid, Reason}, #state{master_db_watcher=Pid} = State) ->
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

master_db(Bucket) ->
    list_to_binary(Bucket ++ "/master").

matching_indexes(Pred, List) ->
    IndexedList = misc:enumerate(List, 0),
    lists:foldr(
      fun ({Ix, Elem}, Acc) ->
              case Pred(Ix, Elem) of
                  true ->
                      [Ix | Acc];
                  false ->
                      Acc
              end
      end, [], IndexedList).

build_map(BucketConfig, VBucketStates) ->
    Map = proplists:get_value(map, BucketConfig),

    case Map of
        undefined ->
            [{active, []}, {passive, []}];
        _ ->
            Active = matching_indexes(
                       fun (Ix, [MasterNode | _]) ->
                               case MasterNode =:= node() of
                                   true ->
                                       VBucketState =
                                           dict:fetch(Ix, VBucketStates),
                                       VBucketState =:= active;
                                   false ->
                                       false
                               end
                       end, Map),

            FFMap = proplists:get_value(fastForwardMap, BucketConfig),
            Passive =
                case FFMap of
                    undefined ->
                        [];
                    _ ->
                        Passive1 =
                            matching_indexes(
                              fun (Ix, [MasterNode | _]) ->
                                      case MasterNode =:= node() of
                                          true ->
                                              VBucketState =
                                                  dict:fetch(Ix, VBucketStates),
                                              VBucketState =:= active orelse
                                                  VBucketState =:= replica;
                                          false ->
                                              false
                                      end
                              end, Map),
                        Passive1 -- Active
                end,

            [{active, Active},
             {passive, Passive}]
    end.

maybe_define_group(Bucket, BucketConfig, DDocId, Map) ->
    SetName = list_to_binary(Bucket),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),

    Active = proplists:get_value(active, Map),
    Passive = proplists:get_value(passive, Map),

    case couch_set_view:is_view_defined(SetName, DDocId) of
        true ->
            ok;
        false ->
            Params = #set_view_params{max_partitions=NumVBuckets,
                                      active_partitions=Active,
                                      passive_partitions=Passive},
            ok = couch_set_view:define_group(SetName, DDocId, Params)
    end.

apply_ddoc_map(Bucket, DDocId, NumVBuckets, Active, Passive, ToRemove) ->
    SetName = list_to_binary(Bucket),

    case couch_set_view:is_view_defined(SetName, DDocId) of
        true ->
            ok = couch_set_view:set_partition_states(SetName, DDocId,
                                                     Active, Passive, ToRemove);
        false ->
            Params = #set_view_params{max_partitions=NumVBuckets,
                                      active_partitions=Active,
                                      passive_partitions=Passive},
            ok = couch_set_view:define_group(SetName, DDocId, Params)
    end.

apply_map(Bucket, BucketConfig, OldMap, NewMap) ->
    DDocDbName = master_db(Bucket),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),

    {ok, DDocDb} = couch_db:open_int(DDocDbName, []),

    {ok, DDocs} =
        try
            couch_db:get_design_docs(DDocDb)
        after
            couch_db:close(DDocDb)
        end,

    ?log_debug("Applying map ~p to bucket ~s", [NewMap, Bucket]),

    Active = proplists:get_value(active, NewMap),
    Passive = proplists:get_value(passive, NewMap),

    ToRemove =
        case OldMap of
            undefined ->
                [];
            _ ->
                OldActive = proplists:get_value(active, OldMap),
                OldPassive = proplists:get_value(passive, OldMap),
                (OldActive ++ OldPassive) -- (Active ++ Passive)
        end,

    ?log_debug("Partitions to remove: ~p", [ToRemove]),

    lists:foreach(
      fun (#doc{id = DDocId} = _DDoc) ->
              apply_ddoc_map(Bucket, DDocId, NumVBuckets,
                             Active, Passive, ToRemove)
      end, DDocs).

get_vbucket_state(Bucket, VBucket) ->
    do_get_vbucket_state(list_to_binary(Bucket), VBucket).

do_get_vbucket_state(Bucket, VBucket) ->
    try
        {JsonState} = ?JSON_DECODE(mc_couch_vbucket:get_state(VBucket, Bucket)),
        State = proplists:get_value(<<"state">>, JsonState),
        erlang:binary_to_atom(State, latin1)
    catch
        throw:{open_db_error, _, _, {not_found, no_db_file}} ->
            dead
    end.

get_vbucket_states(Bucket, BucketConfig) ->
    BucketBinary = list_to_binary(Bucket),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),

    lists:foldl(
      fun (VBucket, States) ->
              State = do_get_vbucket_state(BucketBinary, VBucket),
              dict:store(VBucket, State, States)
      end,
      dict:new(), lists:seq(0, NumVBuckets - 1)).

master_db_watcher(Bucket, Parent) ->
    MasterDbName = master_db(Bucket),
    {ok, MasterDb} = couch_db:open_int(MasterDbName, []),
    Seq = couch_db:get_update_seq(MasterDb),
    ChangesFeedFun = couch_changes:handle_changes(
                       #changes_args{
                          include_docs = false,
                          feed = "continuous",
                          timeout = infinity,
                          db_open_options = [],

                          %% we're interested only in new changes; in case
                          %% there are design documents for which there has
                          %% been no groups defined those will be handled by
                          %% initial call to `apply_map`.
                          since = Seq
                         },
                       {json_req, null},
                       MasterDb
                      ),
    couch_db:close(MasterDb),
    ChangesFeedFun(
      fun({change, {Change}, _}, _) ->
              case proplists:get_value(<<"id">>, Change) of
                  <<"_design/", _/binary>> = DDocId ->
                      ?log_debug("Got change in `~s` design document. "
                                 "Initiating an set view update", [DDocId]),
                      gen_server:cast(Parent, {update_ddoc, DDocId});
                  _ ->
                      ok
              end;
         (_, _) ->
              ok
      end).

apply_current_map(#state{bucket=Bucket} = State) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    VBucketStates = get_vbucket_states(Bucket, BucketConfig),
    Map = build_map(BucketConfig, VBucketStates),
    apply_map(Bucket, BucketConfig, undefined, Map),
    State#state{bucket_config=BucketConfig,
                vbucket_states=VBucketStates,
                map=Map}.

interesting_ns_config_event({buckets, _}) ->
    true;
interesting_ns_config_event(_) ->
    false.

interesting_mc_couch_event({set_vbucket, _, _, _, _}) ->
    true;
interesting_mc_couch_event({flush_all, _}) ->
    true;
interesting_mc_couch_event(_) ->
    false.

mk_filter(Pred) ->
    Self = self(),

    fun (Event, _) ->
            case Pred(Event) of
                true ->
                    Self ! Event;
                false ->
                    ok
            end
    end.
