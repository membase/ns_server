%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

%% XDC Replicator Checkpoint Functions
-module(xdc_vbucket_rep_ckpt).

%% public functions
-export([start_timer/1, cancel_timer/1]).
-export([do_checkpoint/1]).
-export([read_validate_checkpoint/4]).
-export([mass_validate_vbopaque/4]).
-export([get_local_vbuuid/2]).
-export([build_request_base/4, httpdb_to_base_url/1]).

-include("xdc_replicator.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(HTTP_RETRIES, 5).

start_timer(#rep_state{rep_details=#rep{options=Options}} = State) ->
    AfterSecs = proplists:get_value(checkpoint_interval, Options),
    %% convert to milliseconds
    After = AfterSecs*1000,
    %% cancel old timer if exists
    cancel_timer(State),
    %% start a new timer
    case timer:apply_after(After, gen_server, cast, [self(), checkpoint]) of
        {ok, Ref} ->
            Ref;
        Error ->
            ?xdcr_error("Replicator, error scheduling checkpoint:  ~p", [Error]),
            nil
    end.

cancel_timer(#rep_state{timer = nil} = State) ->
    State;
cancel_timer(#rep_state{timer = Timer} = State) ->
    {ok, cancel} = timer:cancel(Timer),
    State#rep_state{timer = nil}.

-spec do_checkpoint(#rep_state{}) -> {ok, binary(), #rep_state{}} |
                                     {checkpoint_commit_failure, binary(), #rep_state{}}.
do_checkpoint(#rep_state{current_through_seq=Seq, committed_seq=Seq} = State) ->
    ?x_trace(noCheckpointNeeded, [{committedSeq, Seq}]),
    {ok, <<"no checkpoint">>, State};
do_checkpoint(#rep_state{remote_vbopaque = {[{old_node_marker, RemoteStartTime}]},
                         target = TargetDB} = State) ->
    ?xdcr_debug("Faking checkpoint into old node"),
    %% note: we're not bumping any counters or reporting anything to
    %% parent. I believe that's fine.
    %%
    %% We're faking actual checkpoint, but we must check remote
    %% instance_start_time to detect possible remote crash
    {ok, Props} = couch_api_wrap:get_db_info(TargetDB),
    NowStartTime = proplists:get_value(<<"instance_start_time">>, Props),
    case NowStartTime =/= undefined andalso NowStartTime =:= RemoteStartTime of
        true ->
            {ok, [], State};
        _ ->
            ?xdcr_debug("Detected remote ep-engine instance restart: ~s vs ~s", [RemoteStartTime, NowStartTime]),
            {checkpoint_commit_failure, {start_time_mismatch, RemoteStartTime, NowStartTime}, State}
    end;
do_checkpoint(#rep_state{rep_details = #rep{id = RepId},
                         current_through_seq = Seq,
                         current_through_snapshot_seq = SnapshotSeq,
                         current_through_snapshot_end_seq = SnapshotEndSeq,
                         status = OldStatus,
                         dcp_failover_uuid = FailoverUUID} = State) ->
    #rep_vb_status{vb = Vb} = OldStatus,

    ?xdcr_info("checkpointing for vb: ~p at ~p",
               [Vb, {Seq, SnapshotSeq, SnapshotEndSeq, FailoverUUID}]),

    SourceBucketName = (State#rep_state.rep_details)#rep.source,

    %% NOTE: we don't need to check if source still has all the
    %% replicated stuff. dcp failover id + seqnos already represent it
    %% well enough. And if any of that is lost, dcp will automatically
    %% rollback to a place that's safe to restart replication from.

    CommitResult = (catch perform_commit_for_checkpoint(State#rep_state.remote_vbopaque,
                                                        State#rep_state.ckpt_api_request_base)),

    case CommitResult of
        {ok, RemoteCommitOpaque} ->
            CheckpointDocId = build_commit_doc_id(State#rep_state.rep_details, Vb),
            NewSeq = State#rep_state.current_through_seq,
            NewSnapshotSeq = State#rep_state.current_through_snapshot_seq,
            NewSnapshotEndSeq = State#rep_state.current_through_snapshot_end_seq,
            {seq_vs_snapshot, true} = {seq_vs_snapshot, (NewSnapshotSeq =< NewSeq)},
            CheckpointDoc = {[{<<"commitopaque">>, RemoteCommitOpaque},
                              {<<"start_time">>, ?l2b(State#rep_state.rep_starttime)},
                              {<<"end_time">>, ?l2b(httpd_util:rfc1123_date())},
                              {<<"failover_uuid">>, FailoverUUID},
                              {<<"seqno">>, NewSeq},
                              {<<"dcp_snapshot_seqno">>, NewSnapshotSeq},
                              {<<"dcp_snapshot_end_seqno">>, NewSnapshotEndSeq}]},
            ns_couchdb_api:update_doc(SourceBucketName,
                                      #doc{id = CheckpointDocId,
                                           body = CheckpointDoc}),
            NewState = State#rep_state{committed_seq = NewSeq,
                                       last_checkpoint_time = os:timestamp()},
            ?x_trace(savedCheckpoint,
                     [{id, CheckpointDocId},
                      {doc, {json, CheckpointDoc}}]),
            ets:update_counter(xdcr_stats, RepId, {#xdcr_stats_sample.succeeded_checkpoints, 1}),
            {ok, [], NewState};
        Other ->
            case Other of
                {mismatch, _} ->
                    ?x_trace(checkpointFailed, [{vbOpaqueMismatch, true}]),
                    ?xdcr_error("Checkpointing failed due to remote vbopaque mismatch: ~p", [Other]);
                _ ->
                    ?x_trace(checkpointFailed, []),
                    ?xdcr_error("Checkpointing failed unexpectedly (or could be network problem): ~p", [Other])
            end,
            ets:update_counter(xdcr_stats, RepId, {#xdcr_stats_sample.failed_checkpoints, 1}),
            {checkpoint_commit_failure, Other, State}
    end.

build_request_base(HttpDB, Bucket, BucketUUID, VBucket) ->
    {URL, BodyBase0, HttpDB} = build_no_vbucket_request_base(HttpDB, Bucket, BucketUUID),
    {URL, [{<<"vb">>, VBucket} | BodyBase0], HttpDB}.

httpdb_to_base_url(HttpDB) ->
    [Scheme, Host, _DbName] = string:tokens(HttpDB#httpdb.url, "/"),
    Scheme ++ "//" ++ Host ++ "/".

build_no_vbucket_request_base(HttpDB, Bucket, BucketUUID) ->
    URL = httpdb_to_base_url(HttpDB),

    BodyBase = [{<<"bucket">>, Bucket},
                {<<"bucketUUID">>, BucketUUID}],
    {URL, BodyBase, HttpDB}.

send_post(Method, ExtraBody, {BaseURL, BodyBase, HttpDB}) ->
    URL = BaseURL ++ Method,
    Headers = [{"Content-Type", "application/json"}],
    BodyJSON = {BodyBase ++ ExtraBody},

    RV = send_retriable_http_request(URL, "POST", Headers, ejson:encode(BodyJSON),
                                     HttpDB#httpdb.timeout,
                                     HttpDB#httpdb.lhttpc_options),
    case RV of
        {ok, {{StatusCode, _ReasonPhrase}, _RespHeaders, RespBody}} ->
            case StatusCode of
                200 ->
                    {Props} = ejson:decode(RespBody),
                    {ok, Props};
                _ ->
                    {error, StatusCode, (catch ejson:decode(RespBody)), RespBody}
            end;
        {error, Reason} ->
            ?xdcr_error("Checkpointing related POST to ~s failed: ~p", [URL, Reason]),
            erlang:error({checkpoint_post_failed, Method, Reason})
    end.

send_retriable_http_request(URL, Method, Headers, Body, Timeout, HTTPOptions) ->
    do_send_retriable_http_request(URL, Method, Headers, Body, Timeout, HTTPOptions, ?HTTP_RETRIES).

is_ssl_error(Reason) ->
    %% note: due to incorrect typespec of lhttpc:request dialyzer
    %% thinks that reason must be atom. So we have to fool it via
    %% nif_error.
    {'EXIT', {ReasonCopy, _}} = (catch erlang:nif_error(Reason)),
    case ReasonCopy of
        {{tls_alert, _}, _} ->
            true;
        _ ->
            false
    end.

is_ssl_error_test() ->
    true = is_ssl_error({{tls_alert, []}, []}),
    false = is_ssl_error("something_else").

do_send_retriable_http_request(URL, Method, Headers, Body, Timeout, HTTPOptions, Retries) ->
    RV = lhttpc:request(URL, Method, Headers, Body, Timeout, HTTPOptions),
    case RV of
        {ok, _} ->
            RV;
        {error, Reason} ->
            case is_ssl_error(Reason) of
                true ->
                    ?xdcr_debug("Got https error doing ~s to ~s. Will NOT retry. Error: ~p", [Method, URL, Reason]),
                    RV;
                false ->
                    NewRetries = Retries - 1,
                    case NewRetries < 0 of
                        true ->
                            RV;
                        _ ->
                            ?xdcr_debug("Got http error doing ~s to ~s. Will retry. Error: ~p", [Method, URL, Reason]),
                            do_send_retriable_http_request(URL, Method, Headers, Body, Timeout, HTTPOptions, NewRetries)
                    end
            end
    end.

build_commit_doc_id(Rep, Vb) ->
    CheckpointDocId0 = iolist_to_binary(couch_httpd:quote(iolist_to_binary([Rep#rep.id, $/, integer_to_list(Vb)]))),
    <<"_local/30-ck-", CheckpointDocId0/binary>>.


perform_commit_for_checkpoint(RemoteVBOpaque, ApiRequestBase) ->
    ReqBody = case RemoteVBOpaque of
                  undefined -> [];
                  _ ->
                      [{<<"vbopaque">>, RemoteVBOpaque}]
              end,

    case send_post("_commit_for_checkpoint", ReqBody, ApiRequestBase) of
        {ok, Props} ->
            case proplists:get_value(<<"commitopaque">>, Props) of
                undefined ->
                    erlang:error({missing_commitopaque_in_commit_for_checkpoint_response, Props});
                CommitOpaque ->
                    ?x_trace(commitForCheckpointOK, [{commitOpaque, {json, CommitOpaque}}]),
                    {ok, CommitOpaque}
            end;
        {error, 400 = _StatusCode, {JSON}, _} when is_list(JSON) ->
            VBOpaque = extract_vbopaque(JSON),
            ?x_trace(gotVBOpaqueMismatch, [{vbopaque, {json, VBOpaque}}]),
            {mismatch, VBOpaque};
        {error, StatusCode, _, Body} ->
            ?x_trace(gotCommitError, [{statusCode, StatusCode}]),
            {error, StatusCode, Body}
    end.

extract_vbopaque(Props) ->
    RemoteVBOpaque = proplists:get_value(<<"vbopaque">>, Props),
    case RemoteVBOpaque =:= undefined of
        true ->
            erlang:error({missing_vbopaque_in_pre_replicate_response, Props});
        _ -> ok
    end,
    RemoteVBOpaque.

perform_pre_replicate(RemoteCommitOpaque, {_, _, HttpDB} = ApiRequestBase, DisableCkptBackwardsCompat) ->
    ReqBody = case RemoteCommitOpaque of
                  undefined -> [];
                  _ ->
                      [{<<"commitopaque">>, RemoteCommitOpaque}]
              end,

    case send_post("_pre_replicate", ReqBody , ApiRequestBase) of
        {ok, Props} ->
            VBOpaque = extract_vbopaque(Props),
            ?x_trace(preReplicateOK, [{vbopaque, {json, VBOpaque}}]),
            {ok, VBOpaque};
        {error, 400 = _StatusCode, {JSON}, _} when is_list(JSON) ->
            ?xdcr_debug("_pre_replicate returned mismatch status: ~p", [JSON]),
            VBOpaque = extract_vbopaque(JSON),
            ?x_trace(preReplicateFailed,
                     [{statusCode, 400},
                      {vbopaque, {json, VBOpaque}}]),
            {mismatch, VBOpaque};
        {error, 404, _, _} when DisableCkptBackwardsCompat =:= false ->
            ?x_trace(preReplicateFailedDueToOldNode, [{statusCode, 404}]),
            ?xdcr_debug("_pre_replicate returned 404. Assuming older node"),
            case couch_api_wrap:get_db_info(HttpDB) of
                {ok, Props} ->
                    {mismatch, {[{old_node_marker, proplists:get_value(<<"instance_start_time">>, Props)}]}};
                Error ->
                    ?xdcr_error("Failed to get dbinfo of remote node (~s): ~p",
                                [misc:sanitize_url(HttpDB#httpdb.url),
                                 Error]),
                    erlang:error({pre_replicate_failed, {get_db_info_failed, Error}})
            end;
        {error, StatusCode, _, Body} ->
            ?x_trace(preReplicateFailed, [{statusCode, StatusCode}]),
            ?xdcr_error("_pre_replicate failed with unexpected status: ~B: ~s", [StatusCode, Body]),
            erlang:error({pre_replicate_failed, StatusCode})
    end.


read_validate_checkpoint(Rep, Vb, ApiRequestBase, DisableCkptBackwardsCompat) ->
    DocId = build_commit_doc_id(Rep, Vb),

    case ns_couchdb_api:get_doc(Rep#rep.source, DocId) of
        {ok, #doc{body = Body}} ->
            parse_validate_checkpoint_doc(Vb, Body, ApiRequestBase, DisableCkptBackwardsCompat);
        {not_found, _} ->
            ?xdcr_debug("Found no local checkpoint document for vb: ~B. Will start from scratch", [Vb]),
            handle_no_checkpoint(ApiRequestBase, DisableCkptBackwardsCompat)
    end.

handle_no_checkpoint(ApiRequestBase, DisableCkptBackwardsCompat) ->
    {_, RemoteVBOpaque} = perform_pre_replicate(undefined, ApiRequestBase, DisableCkptBackwardsCompat),
    handle_no_checkpoint_with_opaque(RemoteVBOpaque).

handle_no_checkpoint_with_opaque(RemoteVBOpaque) ->
    ?x_trace(noCheckpoint, [{vbopaque, {json, RemoteVBOpaque}}]),
    StartSeq = 0,
    {StartSeq, 0, 0, 0,
     RemoteVBOpaque}.

parse_validate_checkpoint_doc(Vb, Body, ApiRequestBase, DisableCkptBackwardsCompat) ->
    try
        do_parse_validate_checkpoint_doc(Vb, Body, ApiRequestBase, DisableCkptBackwardsCompat)
    catch T:E ->
            S = erlang:get_stacktrace(),
            ?xdcr_debug("Got parse_validate_checkpoint_doc exception: ~p:~p~n~p", [T, E, S]),
            erlang:raise(T, E, S)
    end.

do_parse_validate_checkpoint_doc(Vb, Body0, ApiRequestBase, DisableCkptBackwardsCompat) ->
    Body = case Body0 of
               {XB} -> XB;
               _ -> []
           end,
    CommitOpaque = proplists:get_value(<<"commitopaque">>, Body),
    FailoverUUID = proplists:get_value(<<"failover_uuid">>, Body),
    Seqno = proplists:get_value(<<"seqno">>, Body),
    SnapshotSeq = proplists:get_value(<<"dcp_snapshot_seqno">>, Body),
    SnapshotEndSeq = proplists:get_value(<<"dcp_snapshot_end_seqno">>, Body),
    ?x_trace(gotExistingCheckpoint, [{body, {json, {Body}}}]),
    case (CommitOpaque =/= undefined andalso
          is_integer(FailoverUUID) andalso
          is_integer(Seqno) andalso
          is_integer(SnapshotSeq) andalso
          is_integer(SnapshotEndSeq)) of
        false ->
            handle_no_checkpoint(ApiRequestBase, DisableCkptBackwardsCompat);
        true ->
            case perform_pre_replicate(CommitOpaque, ApiRequestBase, DisableCkptBackwardsCompat) of
                {mismatch, RemoteVBOpaque} ->
                    ?xdcr_debug("local checkpoint for vb ~B does not match due to remote side. Checkpoint seqno: ~B. xdcr will start from scratch", [Vb, Seqno]),
                    handle_no_checkpoint_with_opaque(RemoteVBOpaque);
                {ok, RemoteVBOpaque} ->
                    ?xdcr_debug("local checkpoint for vb ~B matches. Seqno: ~B", [Vb, Seqno]),
                    StartSeq = Seqno,
                    {StartSeq, SnapshotSeq, SnapshotEndSeq,
                     FailoverUUID,
                     RemoteVBOpaque}
            end
    end.

get_local_vbuuid(BucketName, Vb) ->
    {ok, KV} = ns_memcached:stats(couch_util:to_list(BucketName), io_lib:format("vbucket-seqno ~B", [Vb])),
    Key = iolist_to_binary(io_lib:format("vb_~B:uuid", [Vb])),
    misc:expect_prop_value(Key, KV).

-spec mass_validate_vbopaque(#httpdb{}, binary(), binary(),
                             [#xdcr_vb_stats_sample{}]) ->
                                    [#xdcr_vb_stats_sample{}] | {error, _, _, _} | {other_error, _}.
mass_validate_vbopaque(HttpDB, TargetRef, UUID, StatsSamples) ->
    {ok, {_, BucketNameString}} = remote_clusters_info:parse_remote_bucket_reference(TargetRef),
    BucketName = erlang:list_to_binary(BucketNameString),
    RBase = build_no_vbucket_request_base(HttpDB, BucketName, UUID),
    Pairs = [case Sample of
                 #xdcr_vb_stats_sample{id_and_vb = {_, Vb}, remote_vbopaque = Opaque} ->
                     [Vb, Opaque]
             end || Sample <- StatsSamples],
    Body = [{<<"vbopaques">>, Pairs}],
    case (catch send_post("_mass_vbopaque_check", Body, RBase)) of
        {ok, Props} ->
            handle_mass_vbopaque_success(Props, StatsSamples);
        {error, _StatusCode, _BodyJSON, _Body} = Err ->
            Err;
        OtherError ->
            {other_error, OtherError}
    end.

handle_mass_vbopaque_success(Props, StatsSamples) ->
    Mismatched = proplists:get_value(<<"mismatched">>, Props, []),
    Missing = proplists:get_value(<<"missing">>, Props, []),
    BadVbs = lists:sort([Vb || [Vb | _] <- Mismatched] ++ Missing),
    SortedSamples = lists:sort(
                      fun (#xdcr_vb_stats_sample{id_and_vb = {_, VbA}},
                           #xdcr_vb_stats_sample{id_and_vb = {_, VbB}}) ->
                              VbA =< VbB
                      end, StatsSamples),
    handle_mass_vbopaque_success_loop(BadVbs, SortedSamples, []).

handle_mass_vbopaque_success_loop([Vb | RestVbs] = BadVbs,
                                  [FirstSample | RestSamples],
                                  Acc) ->
    #xdcr_vb_stats_sample{id_and_vb = {_, SampleVb}} = FirstSample,
    if
        SampleVb < Vb ->
            handle_mass_vbopaque_success_loop(BadVbs, RestSamples, Acc);
        SampleVb =:= Vb ->
            handle_mass_vbopaque_success_loop(RestVbs, RestSamples,
                                              [FirstSample | Acc]);
        true ->
            erlang:error({unknown_vb, Vb, FirstSample})
    end;
handle_mass_vbopaque_success_loop([], _RestSamples, Acc) ->
    Acc.
