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

%% Maintains design doc replication, each node contains its osn design doc
%% master database for each vbucket which is replicated to all vbuckets on
%% this node, it also pull replicates from each other node within the
%% cluster

-module(capi_ddoc_replication_srv).

-behaviour(gen_server).

-include("couch_replicator.hrl").
-include("couch_api_wrap.hrl").
-include("couch_db.hrl").
-include("ns_common.hrl").

-define(i2l(V), integer_to_list(V)).


-export([start_link/1, force_update/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bucket, master, servers = [], vbuckets = []}).


start_link(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            ignore;
        _ ->
            gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, [])
    end.

force_update(Bucket) ->
    server(Bucket) ! update.

init(Bucket) ->

    Self = self(),
    MasterVBucket = ?l2b(Bucket ++ "/" ++ "master"),

    case couch_db:open(MasterVBucket, []) of
        {ok, Db} ->
            couch_db:close(Db);
        {not_found, _} ->
            {ok, Db} = couch_db:create(MasterVBucket, []),
            couch_db:close(Db)
    end,

    % Update myself whenever the config changes (rebalance)
    ns_pubsub:subscribe(
      ns_config_events,
      fun (_, _) -> Self ! update end,
      empty),

    Self ! update,

    erlang:process_flag(trap_exit, true),
    {ok, #state{bucket=Bucket, master=MasterVBucket}}.


handle_call(_Request, _From, State) ->
    {reply, ok, State}.


handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(update, State) ->
    {noreply, update(State)};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(Reason, _State) when Reason =:= normal orelse Reason =:= shutdown ->
    ok;
terminate(Reason, _State) ->
    %% Sometimes starting replication fails because of vbucket
    %% databases creation race or (potentially) because of remote node
    %% unavailability. When this process repeatedly fails our
    %% supervisor ends up dying due to
    %% max_restart_intensity_reached. Because we'll change our local
    %% ddocs replication mechanism lets simply delay death a-la
    %% supervisor_cushion to prevent that.
    ?log_info("Delaying death during unexpected termination: ~p~n", [Reason]),
    timer:sleep(3000),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


update(#state{vbuckets=VBuckets, servers=Servers,
              bucket=Bucket, master=Master} = State) ->

    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    Self = node(),

    Fun = fun([X|_], {Num, List}) when X =:= Self ->
                  {Num + 1, [Num | List]};
             (_, {Index, List}) ->
                  {Index + 1, List}
          end,

    Map = case proplists:get_value(map, Conf) of
              undefined -> [];
              TheMap -> TheMap
          end,

    {_, NVBucketsAll} = lists:foldl(Fun, {0, []}, Map),

    {ok, VBucketStates} = ns_memcached:list_vbuckets(Bucket),
    PresentVBuckets = lists:sort(proplists:get_keys(VBucketStates)),

    NVBucketsPresent = ordsets:intersection(lists:sort(NVBucketsAll),
                                            PresentVBuckets),

    NServers = proplists:get_value(servers, Conf) -- [Self],

    {ToStartVBuckets0, ToStopVBuckets} = difference(VBuckets, NVBucketsAll),
    {ToStartServers, ToStopServers} = difference(Servers, NServers),

    ToStartVBuckets = ordsets:intersection(lists:sort(ToStartVBuckets0), PresentVBuckets),

    [stop_server_replication(Master, Bucket, Srv) || Srv <- ToStopServers],
    [start_server_replication(Master, Bucket, Srv) || Srv <- ToStartServers],

    [stop_vbucket_replication(Master, Bucket, Srv) || Srv <- ToStopVBuckets],
    [start_vbucket_replication(Master, Bucket, Srv) || Srv <- ToStartVBuckets],

    State#state{vbuckets=NVBucketsPresent, servers=NServers}.


build_replication_struct(Source, Target) ->
    {ok, Replication} =
        couch_replicator_utils:parse_rep_doc(
          {[{<<"source">>, Source},
            {<<"target">>, Target}
            | default_opts()]},
          default_user()),
    Replication.

remote_master_url(Bucket, Node) ->
    Url = capi_utils:capi_url(Node, "/" ++ mochiweb_util:quote_plus(Bucket) ++ "%2Fmaster", "127.0.0.1"),
    ?l2b(Url).

start_server_replication(Master, Bucket, Node) ->
    Replication =
        build_replication_struct(remote_master_url(Bucket, Node),
                                 Master),

    {ok, _Res} = couch_replicator:replicate(Replication).


stop_server_replication(Master, Bucket, Node) ->
    Replication =
        build_replication_struct(remote_master_url(Bucket, Node),
                                 Master),

    {ok, _Res} = couch_replicator:cancel_replication(Replication#rep.id).


start_vbucket_replication(Master, Bucket, VBucket) ->

    Replication =
        build_replication_struct(Master,
                                 ?l2b(Bucket ++ "/"++ ?i2l(VBucket))),

    {ok, _Res} = couch_replicator:replicate(Replication).


stop_vbucket_replication(Master, Bucket, VBucket) ->

    Replication =
        build_replication_struct(Master,
                                 ?l2b(Bucket ++ "/"++ ?i2l(VBucket))),

    {ok, _Res} = couch_replicator:cancel_replication(Replication#rep.id).


difference(List1, List2) ->
    {List2 -- List1, List1 -- List2}.


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).


default_user() ->
    #user_ctx{roles=[<<"_admin">>]}.

default_opts() ->
    [{<<"continuous">>, true},
     {<<"worker_processes">>, 1},
     {<<"http_connections">>, 10}
    ].
