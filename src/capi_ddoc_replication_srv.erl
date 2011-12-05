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

%% Maintains design document replication between the <BucketName>/master
%% vbuckets (CouchDB databases) of all cluster nodes.

-module(capi_ddoc_replication_srv).

-behaviour(gen_server).

-include("couch_replicator.hrl").
-include("couch_api_wrap.hrl").
-include("couch_db.hrl").
-include("ns_common.hrl").


-export([start_link/1, force_update/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bucket,
                master,
                servers = [],
                retry_timer}).

-define(RETRY_AFTER, 5000).

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

    Self ! start_replication,

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

handle_info(start_replication, State) ->
    {noreply, start_replication(State)};

handle_info({'DOWN', _Ref, process, _Pid, Reason}, State)
  when Reason =:= normal orelse Reason =:= shutdown ->
    {noreply, State};
handle_info({'DOWN', _Ref, process, _Pid, Reason}, State) ->
    ?log_info("Replication slave crashed with reason: ~p", [Reason]),
    {noreply, start_replication(State)}.

terminate(Reason, State) when Reason =:= normal orelse Reason =:= shutdown ->
    stop_replication(State),
    ok;
terminate(Reason, State) ->
    stop_replication(State),
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


get_all_servers(Bucket) ->
    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    Self = node(),

    proplists:get_value(servers, Conf) -- [Self].

stop_retry_timer(#state{retry_timer=undefined} = State) ->
    State;
stop_retry_timer(#state{retry_timer=Timer} = State) ->
    {ok, cancel} = timer:cancel(Timer),
    State#state{retry_timer=undefined}.

retry(#state{retry_timer=undefined} = State) ->
    {ok, Timer} = timer:send_after(?RETRY_AFTER, update),
    State#state{retry_timer=Timer};
retry(State) ->
    retry(stop_retry_timer(State)).

start_replication(State) ->
    update(State#state{servers=[]}).

stop_replication(#state{bucket=Bucket, master=Master, servers=Servers} = State) ->
    [stop_server_replication(Master, Bucket, Srv) || Srv <- Servers],
    stop_retry_timer(State#state{servers=[]}).

update(#state{servers=Servers,
              bucket=Bucket, master=Master} = State, NewServers) ->
    {ToStartServers, ToStopServers} = difference(Servers, NewServers),
    ToKeep = Servers -- (ToStartServers ++ ToStopServers),

    {Started, Failed} =
        lists:foldl(
          fun (Srv, {AccStarted, AccFailed}) ->
                  case start_server_replication(Master, Bucket, Srv) of
                      ok ->
                          {[Srv | AccStarted], AccFailed};
                      Error ->
                          ?log_error("Failed to start ddoc replication to ~p: ~p",
                                     [Srv, Error]),
                          {AccStarted, [Srv | AccFailed]}
                  end
          end, {[], []}, ToStartServers),

    [stop_server_replication(Master, Bucket, Srv) || Srv <- ToStopServers],

    State1 = State#state{servers=ToKeep ++ Started},
    case Failed of
        [] ->
            State1;
        _Other ->
            retry(State1)
    end.

update(#state{bucket=Bucket} = State) ->
    update(State, get_all_servers(Bucket)).

build_replication_struct(Source, Target) ->
    {ok, Replication} =
        couch_replicator_utils:parse_rep_doc(
          {[{<<"source">>, Source},
            {<<"target">>, Target}
            | default_opts()]},
          #user_ctx{roles = [<<"_admin">>]}),
    Replication.

start_server_replication(Master, Bucket, Node) ->
    Opts = build_replication_struct(remote_master_url(Bucket, Node), Master),
    case couch_replicator:async_replicate(Opts) of
        {ok, Pid} ->
            erlang:monitor(process, Pid),
            ok;
        Error ->
            Error
    end.

stop_server_replication(Master, Bucket, Node) ->
    Opts = build_replication_struct(remote_master_url(Bucket, Node), Master),
    {ok, _Res} = couch_replicator:cancel_replication(Opts#rep.id).


remote_master_url(Bucket, Node) ->
    Url = capi_utils:capi_url(Node, "/" ++ mochiweb_util:quote_plus(Bucket)
                              ++ "%2Fmaster", "127.0.0.1"),
    ?l2b(Url).


difference(List1, List2) ->
    {List2 -- List1, List1 -- List2}.


%% @doc Generate a suitable name for the per-bucket gen_server.
server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).


default_opts() ->
    [{<<"continuous">>, true},
     {<<"worker_processes">>, 1},
     {<<"http_connections">>, 10}
    ].
