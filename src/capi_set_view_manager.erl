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

-define(SYNC_INTERVAL, 5000).

%% API
-export([start_link/1, wait_until_added/3]).

-include("couch_db.hrl").
-include_lib("couch_set_view/include/couch_set_view.hrl").
-include("ns_common.hrl").

-record(state, {bucket,
                bucket_config,
                vbucket_states,
                master_db_watcher,
                map,
                ddocs,
                pending_vbucket_states,
                waiters}).

start_link(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            ignore;
        _ ->
            gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, [])
    end.

wait_until_added(Node, Bucket, VBucket) ->
    Address = {server(Bucket), Node},
    gen_server:call(Address, {wait_until_added, VBucket}, infinity).

init(Bucket) ->
    process_flag(trap_exit, true),

    InterestingNsConfigEvent =
        fun (Event) ->
                interesting_ns_config_event(Bucket, Event)
        end,

    ns_pubsub:subscribe(ns_config_events,
                        mk_filter(InterestingNsConfigEvent), ignored),
    ns_pubsub:subscribe(mc_couch_events,
                        mk_mc_couch_event_hander(), ignored),

    Self = self(),
    Watcher =
        spawn_link(
          fun () ->
                  master_db_watcher(Bucket, Self)
          end),

    %% synchronize with watcher to avoid a race; potentially we could ignore
    %% some design documents (if they are created after the initial list is
    %% read in apply_current_map but before master db watcher is able to
    %% monitor changes)
    receive
        {watcher_started, Watcher} ->
            ok
    end,

    {ok, _Timer} = timer:send_interval(?SYNC_INTERVAL, sync),

    State = #state{bucket=Bucket,
                   master_db_watcher=Watcher,
                   ddocs=undefined,
                   waiters=dict:new()},

    {ok, apply_current_map(State)}.

handle_call({wait_until_added, VBucket}, From,
            #state{waiters=Waiters} = State) ->
    case added(VBucket, State) of
        true ->
            {reply, ok, State};
        false ->
            Waiters1 = dict:append(VBucket, From, Waiters),
            State1 = State#state{waiters=Waiters1},
            {noreply, State1}
    end;

handle_call(sync, _From, State) ->
    {reply, ok, sync(State)};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({update_ddoc, DDocId, Deleted},
            #state{bucket=Bucket,
                   bucket_config=BucketConfig,
                   ddocs=DDocs, map=Map} = State) ->
    State1 =
        case Deleted of
            false ->
                %% we need to redefine set view whenever document changes
                define_group(Bucket, BucketConfig, DDocId, Map),
                DDocs1 = sets:add_element(DDocId, DDocs),
                State#state{ddocs=DDocs1};
            true ->
                DDocs1 = sets:del_element(DDocId, DDocs),
                State#state{ddocs=DDocs1}
        end,

    {noreply, State1};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({buckets, Buckets},
            #state{bucket=Bucket} = State) ->
    ?log_debug("Got `buckets` event"),

    BucketConfigs = proplists:get_value(configs, Buckets),
    BucketConfig = proplists:get_value(Bucket, BucketConfigs),

    NewState = State#state{bucket_config=BucketConfig},
    {noreply, sync(NewState)};

handle_info({set_vbucket, Bucket, VBucket, _VBucketState, _CheckpointId},
            #state{bucket=Bucket,
                   pending_vbucket_states=PendingStates} = State) ->
    VBucketState = get_vbucket_state(Bucket, VBucket),

    ?log_debug("Got set_vbucket event for ~s/~b. Updated state: ~p",
               [Bucket, VBucket, VBucketState]),

    NewPendingStates = dict:store(VBucket, VBucketState, PendingStates),
    NewState = State#state{pending_vbucket_states=NewPendingStates},

    {noreply, NewState};

handle_info({flush_all, Bucket}, #state{bucket=Bucket} = State) ->
    {noreply, apply_current_map(State)};

handle_info(sync, State) ->
    {noreply, sync(State)};

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

matching_vbuckets(Pred, Map, States) ->
    matching_indexes(
      fun (Ix, [MasterNode | _]) ->
              case MasterNode =:= node() of
                  true ->
                      VBucketState = dict:fetch(Ix, States),
                      Pred(Ix, VBucketState);
                  false ->
                      false
              end
      end, Map).

build_map(BucketConfig, VBucketStates) ->
    Map = proplists:get_value(map, BucketConfig),

    case Map of
        undefined ->
            [{active, []}, {passive, []}, {ignore, []}];
        _ ->
            Active = matching_vbuckets(
                       fun (_Vb, State) ->
                               State =:= active
                       end, Map, VBucketStates),

            Ignore = matching_vbuckets(
                       fun (_Vb, State) ->
                               State =:= dead
                       end, Map, VBucketStates),

            FFMap = proplists:get_value(fastForwardMap, BucketConfig),
            Passive =
                case FFMap of
                    undefined ->
                        [];
                    _ ->
                        Passive1 =
                            matching_vbuckets(
                              fun (_Vb, State) ->
                                      State =:= active orelse
                                          State =:= replica orelse
                                          State =:= pending
                              end, FFMap, VBucketStates),
                        Passive1 -- Active
                end,

            [{active, Active},
             {passive, Passive},
             {ignore, Ignore}]
    end.

define_group(Bucket, BucketConfig, DDocId, Map) ->
    SetName = list_to_binary(Bucket),
    NumVBuckets = proplists:get_value(num_vbuckets, BucketConfig),

    Active = proplists:get_value(active, Map),
    Passive = proplists:get_value(passive, Map),

    Params = #set_view_params{max_partitions=NumVBuckets,
                              active_partitions=Active,
                              passive_partitions=Passive},

    try
        ok = couch_set_view:define_group(SetName, DDocId, Params)
    catch
        throw:{not_found, deleted} ->
            %% The document has been deleted but we still think it's
            %% alive. Eventually we will get a notification from master db
            %% watcher and delete it from a list of design documents.
            ok
    end.

maybe_define_group(Bucket, BucketConfig, DDocId, Map) ->
    try
        define_group(Bucket, BucketConfig, DDocId, Map)
    catch
        throw:view_already_defined ->
            ok
    end.

apply_ddoc_map(Bucket, DDocId, Active, Passive, ToRemove) ->
    SetName = list_to_binary(Bucket),

    try
        ok = couch_set_view:set_partition_states(SetName, DDocId,
                                                 Active, Passive, ToRemove)
    catch
        throw:{not_found, deleted} ->
            %% The document has been deleted but we still think it's
            %% alive. Eventually we will get a notification from master db
            %% watcher and delete it from a list of design documents.
            ok;
        throw:view_undefined ->
            %% Design document has been updated but we have not reacted on it
            %% yet. As previously eventually we will get a notification about
            %% this change and define a group again.
            ok
    end.

apply_map(Bucket, DDocs, OldMap, NewMap) ->
    ?log_debug("Applying map ~p to bucket ~s", [NewMap, Bucket]),

    Active = proplists:get_value(active, NewMap),
    Passive = proplists:get_value(passive, NewMap),
    Ignore = proplists:get_value(ignore, NewMap),

    ToRemove =
        case OldMap of
            undefined ->
                [];
            _ ->
                OldActive = proplists:get_value(active, OldMap),
                OldPassive = proplists:get_value(passive, OldMap),
                OldIgnore = proplists:get_value(ignore, OldMap),

                (OldActive ++ OldPassive ++ OldIgnore) --
                    (Active ++ Passive ++ Ignore)
        end,

    ?log_debug("Partitions to remove: ~p", [ToRemove]),

    sets:fold(
      fun (DDocId, _) ->
              apply_ddoc_map(Bucket, DDocId, Active, Passive, ToRemove)
      end, undefined, DDocs).

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

    %% we've read a update seq from db; thus even though actual loop is not
    %% started we can safely pretend that it really is; even if any design doc
    %% is created in between it will be included in a changes that are
    %% reported to the main process.
    Parent ! {watcher_started, self()},

    ChangesFeedFun(
      fun({change, {Change}, _}, _) ->
              Deleted = proplists:get_value(<<"deleted">>, Change, false),

              case proplists:get_value(<<"id">>, Change) of
                  <<"_design/", _/binary>> = DDocId ->
                      ?log_debug("Got change in `~s` design document. "
                                 "Initiating set view update", [DDocId]),
                      gen_server:cast(Parent, {update_ddoc, DDocId, Deleted});
                  _ ->
                      ok
              end;
         (_, _) ->
              ok
      end).

apply_current_map(#state{bucket=Bucket} = State) ->
    DDocs = get_design_docs(Bucket),

    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    VBucketStates = get_vbucket_states(Bucket, BucketConfig),
    Map = build_map(BucketConfig, VBucketStates),

    sets:fold(
      fun (DDocId, _) ->
              maybe_define_group(Bucket, BucketConfig, DDocId, Map)
      end, undefined, DDocs),

    apply_map(Bucket, DDocs, undefined, Map),
    State#state{bucket_config=BucketConfig,
                vbucket_states=VBucketStates,
                pending_vbucket_states=VBucketStates,
                map=Map,
                ddocs=DDocs}.

interesting_ns_config_event(Bucket, {buckets, Buckets}) ->
    BucketConfigs = proplists:get_value(configs, Buckets, []),
    proplists:is_defined(Bucket, BucketConfigs);
interesting_ns_config_event(_Bucket, _) ->
    false.

mk_mc_couch_event_hander() ->
    Self = self(),

    fun (Event, _) ->
            handle_mc_couch_event(Self, Event)
    end.

handle_mc_couch_event(Self,
                      {pre_set_vbucket, Bucket, VBucket, State, Checkpoint}) ->
    case State of
        dead ->
            Self ! {set_vbucket, Bucket, VBucket, State, Checkpoint},
            ok = gen_server:call(Self, sync);
        _ ->
            ok
    end;
handle_mc_couch_event(Self,
                      {post_set_vbucket, Bucket, VBucket, State, Checkpoint}) ->
    case State of
        dead ->
            ok;
        _ ->
            Self ! {set_vbucket, Bucket, VBucket, State, Checkpoint}
    end;
handle_mc_couch_event(Self, {flush_all, _} = Event) ->
    Self ! Event;
handle_mc_couch_event(_, _) ->
    ok.

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

sync(#state{bucket=Bucket,
            bucket_config=BucketConfig,
            pending_vbucket_states=PendingStates,
            ddocs=DDocs,
            map=Map,
            waiters=Waiters} = State) ->
    NewMap = build_map(BucketConfig, PendingStates),
    case NewMap =/= Map of
        true ->
            apply_map(Bucket, DDocs, Map, NewMap),
            Waiters1 = notify_waiters(Waiters, NewMap),
            State#state{vbucket_states=PendingStates,
                        map=NewMap, waiters=Waiters1};
        false ->
            State#state{vbucket_states=PendingStates}
    end.

get_design_docs(Bucket) ->
    DDocDbName = master_db(Bucket),

    {ok, DDocDb} = couch_db:open(DDocDbName,
                                 [{user_ctx, #user_ctx{roles=[<<"_admin">>]}}]),
    {ok, DDocs} =
        try
            couch_db:get_design_docs(DDocDb)
        after
            couch_db:close(DDocDb)
        end,

    DDocIds = lists:map(fun (#doc{id=DDocId}) ->
                                DDocId
                        end, DDocs),
    sets:from_list(DDocIds).

added(VBucket, #state{map=Map}) ->
    Active = proplists:get_value(active, Map),
    Passive = proplists:get_value(passive, Map),

    lists:member(VBucket, Active)
        orelse lists:member(VBucket, Passive).

notify_waiters(Waiters, Map) ->
    Active = proplists:get_value(active, Map),
    Passive = proplists:get_value(passive, Map),

    Waiters1 = do_notify_waiters(Waiters, Active),
    do_notify_waiters(Waiters1, Passive).

do_notify_waiters(Waiters, Partitions) ->
    lists:foldl(
      fun (P, AccWaiters) ->
              case dict:find(P, AccWaiters) of
                  {ok, Froms} ->
                      [gen_server:reply(From, ok) || From <- Froms],
                      dict:erase(P, AccWaiters);
                  error ->
                      AccWaiters
              end
      end, Waiters, Partitions).
