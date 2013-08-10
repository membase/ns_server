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

%% XDC Replication Specific Utility Functions

-module(xdc_rep_utils).

-export([parse_rep_doc/2]).
-export([local_couch_uri_for_vbucket/2]).
-export([remote_couch_uri_for_vbucket/3, my_active_vbuckets/1]).
-export([parse_rep_db/3]).
-export([split_dbname/1]).
-export([get_master_db/1, get_checkpoint_log_id/2]).
-export([get_opt_replication_threshold/0]).
-export([update_options/1, get_checkpoint_mode/0]).
-export([get_replication_mode/0, get_replication_batch_size/0]).
-export([is_pipeline_enabled/0, get_trace_dump_invprob/0]).
-export([get_xmem_worker/0, is_local_conflict_resolution/0]).
-export([sanitize_status/3]).

-include("xdc_replicator.hrl").

%% Given a Bucket name and a vbucket id, this function computes the Couch URI to
%% locally access it.
local_couch_uri_for_vbucket(BucketName, VbucketId) ->
    iolist_to_binary([BucketName, $/, integer_to_list(VbucketId)]).


%% Given the vbucket map and node list of a remote bucket and a vbucket id, this
%% function computes the CAPI URI to access it.
remote_couch_uri_for_vbucket(VbucketMap, NodeList, VbucketId) ->
    [Owner | _ ] = lists:nth(VbucketId+1, VbucketMap),
    {OwnerNodeProps} = lists:nth(Owner+1, NodeList),
    CapiBase = couch_util:get_value(<<"couchApiBase">>, OwnerNodeProps),
    iolist_to_binary([CapiBase, "%2F", integer_to_list(VbucketId)]).


%% Given a bucket config, this function computes a list of active vbuckets
%% currently owned by the executing node.
my_active_vbuckets(BucketConfig) ->
    VBucketMap = couch_util:get_value(map, BucketConfig),
    [Ordinal-1 ||
        {Ordinal, Owner} <- misc:enumerate([Head || [Head|_] <- VBucketMap]),
        Owner == node()].

%% Parse replication document
parse_rep_doc(DocId, {Props}) ->
    ProxyParams = parse_proxy_params(get_value(<<"proxy">>, Props, <<>>)),
    Options = make_options(Props),
    Source = parse_rep_db(get_value(<<"source">>, Props), ProxyParams, Options),
    Target = parse_rep_db(get_value(<<"target">>, Props), ProxyParams, Options),
    #rep{id = DocId,
         source = Source,
         target = Target,
         options = Options}.

parse_proxy_params(ProxyUrl) when is_binary(ProxyUrl) ->
    parse_proxy_params(?b2l(ProxyUrl));
parse_proxy_params([]) ->
    [];
parse_proxy_params(ProxyUrl) ->
    [{proxy, ProxyUrl}].

parse_rep_db({Props}, ProxyParams, Options) ->
    Url = maybe_add_trailing_slash(get_value(<<"url">>, Props)),
    {AuthProps} = get_value(<<"auth">>, Props, {[]}),
    {BinHeaders} = get_value(<<"headers">>, Props, {[]}),
    Headers = lists:ukeysort(1, [{?b2l(K), ?b2l(V)} || {K, V} <- BinHeaders]),
    DefaultHeaders = (#httpdb{})#httpdb.headers,
    OAuth = case get_value(<<"oauth">>, AuthProps) of
                undefined ->
                    nil;
                {OauthProps} ->
                    #oauth{
                  consumer_key = ?b2l(get_value(<<"consumer_key">>, OauthProps)),
                  token = ?b2l(get_value(<<"token">>, OauthProps)),
                  token_secret = ?b2l(get_value(<<"token_secret">>, OauthProps)),
                  consumer_secret = ?b2l(get_value(<<"consumer_secret">>, OauthProps)),
                  signature_method =
                      case get_value(<<"signature_method">>, OauthProps) of
                          undefined ->        hmac_sha1;
                          <<"PLAINTEXT">> ->  plaintext;
                          <<"HMAC-SHA1">> ->  hmac_sha1;
                          <<"RSA-SHA1">> ->   rsa_sha1
                      end
                 }
            end,
    SslParams = ssl_params(Url),
    ProxyParams2 = case SslParams of
                       [] ->
                           ProxyParams;
                       _ when ProxyParams =/= [] ->
                           [{proxy_ssl_options, SslParams} | ProxyParams];
                       _ ->
                           ProxyParams
                   end,
    ConnectOpts = get_value(socket_options, Options) ++ ProxyParams2 ++ SslParams,
    Timeout = get_value(connection_timeout, Options),
    LhttpcOpts = lists:keysort(1, [
                                   {connect_options, ConnectOpts},
                                   {connect_timeout, Timeout},
                                   {send_retry, 0}
                                  ]),
    #httpdb{
             url = Url,
             oauth = OAuth,
             headers = lists:ukeymerge(1, Headers, DefaultHeaders),
             lhttpc_options = LhttpcOpts,
             timeout = Timeout,
             http_connections = get_value(http_connections, Options),
             retries = get_value(retries, Options)
           };
parse_rep_db(<<"http://", _/binary>> = Url, ProxyParams, Options) ->
    parse_rep_db({[{<<"url">>, Url}]}, ProxyParams, Options);
parse_rep_db(<<"https://", _/binary>> = Url, ProxyParams, Options) ->
    parse_rep_db({[{<<"url">>, Url}]}, ProxyParams, Options);
parse_rep_db(<<DbName/binary>>, _ProxyParams, _Options) ->
    DbName.

make_options(Props) ->
    Options = lists:ukeysort(1, convert_options(Props)),

    {value, DefaultWorkerBatchSize} = ns_config:search(xdcr_worker_batch_size),
    DefBatchSize = misc:getenv_int("XDCR_WORKER_BATCH_SIZE", DefaultWorkerBatchSize),

    {value, DefaultConnTimeout} = ns_config:search(xdcr_connection_timeout),
    DefTimeoutSecs = misc:getenv_int("XDCR_CONNECTION_TIMEOUT", DefaultConnTimeout),
    %% convert to ms
    DefTimeout = 1000*DefTimeoutSecs,

    {value, DefaultWorkers} = ns_config:search(xdcr_num_worker_process),
    DefWorkers = misc:getenv_int("XDCR_NUM_WORKER_PROCESS", DefaultWorkers),

    {value, DefaultConns} = ns_config:search(xdcr_num_http_connections),
    DefConns = misc:getenv_int("XDCR_NUM_HTTP_CONNECTIONS", DefaultConns),

    {value, DefaultRetries} = ns_config:search(xdcr_num_retries_per_request),
    DefRetries = misc:getenv_int("XDCR_NUM_RETRIES_PER_REQUEST", DefaultRetries),

    {ok, DefSocketOptions} = couch_util:parse_term(
                               couch_config:get("replicator", "socket_options",
                                                "[{keepalive, true}, {nodelay, false}]")),

    OptRepThreshold = get_opt_replication_threshold(),

    ?xdcr_debug("Options for replication:["
                "optimistic replication threshold: ~p bytes, "
                "worker processes: ~p, "
                "worker batch size (# of mutations): ~p, "
                "socket options: ~p "
                "HTTP connections: ~p, "
                "connection timeout (ms): ~p,"
                "num of retries per request: ~p]",
                [OptRepThreshold, DefWorkers, DefBatchSize, DefSocketOptions, DefConns, DefTimeout, DefRetries]),

    lists:ukeymerge(1, Options, lists:keysort(1, [
                                                  {connection_timeout, DefTimeout},
                                                  {retries, DefRetries},
                                                  {http_connections, DefConns},
                                                  {socket_options, DefSocketOptions},
                                                  {worker_batch_size, DefBatchSize},
                                                  {worker_processes, DefWorkers},
                                                  {opt_rep_threshold, OptRepThreshold}
                                                 ])).


maybe_add_trailing_slash(Url) when is_binary(Url) ->
    maybe_add_trailing_slash(?b2l(Url));
maybe_add_trailing_slash(Url) ->
    case lists:last(Url) of
        $/ ->
            Url;
        _ ->
            Url ++ "/"
    end.




ssl_params(Url) ->
    case lhttpc_lib:parse_url(Url) of
        #lhttpc_url{is_ssl = true} ->
            Depth = list_to_integer(
                      couch_config:get("replicator", "ssl_certificate_max_depth", "3")
                     ),
            VerifyCerts = couch_config:get("replicator", "verify_ssl_certificates"),
            SslOpts = [{depth, Depth} | ssl_verify_options(VerifyCerts =:= "true")],
            [{is_ssl, true}, {ssl_options, SslOpts}, {proxy_ssl_options, SslOpts}];
        _ ->
            []
    end.

ssl_verify_options(Value) ->
    ssl_verify_options(Value, erlang:system_info(otp_release)).

ssl_verify_options(true, OTPVersion) when OTPVersion >= "R14" ->
    CAFile = couch_config:get("replicator", "ssl_trusted_certificates_file"),
    [{verify, verify_peer}, {cacertfile, CAFile}];
ssl_verify_options(false, OTPVersion) when OTPVersion >= "R14" ->
    [{verify, verify_none}];
ssl_verify_options(true, _OTPVersion) ->
    CAFile = couch_config:get("replicator", "ssl_trusted_certificates_file"),
    [{verify, 2}, {cacertfile, CAFile}];
ssl_verify_options(false, _OTPVersion) ->
    [{verify, 0}].



convert_options([])->
    [];
convert_options([{<<"worker_processes">>, V} | R]) ->
    [{worker_processes, couch_util:to_integer(V)} | convert_options(R)];
convert_options([{<<"worker_batch_size">>, V} | R]) ->
    [{worker_batch_size, couch_util:to_integer(V)} | convert_options(R)];
convert_options([{<<"http_connections">>, V} | R]) ->
    [{http_connections, couch_util:to_integer(V)} | convert_options(R)];
convert_options([{<<"connection_timeout">>, V} | R]) ->
    [{connection_timeout, couch_util:to_integer(V)} | convert_options(R)];
convert_options([{<<"retries_per_request">>, V} | R]) ->
    [{retries, couch_util:to_integer(V)} | convert_options(R)];
convert_options([{<<"socket_options">>, V} | R]) ->
    {ok, SocketOptions} = couch_util:parse_term(V),
    [{socket_options, SocketOptions} | convert_options(R)];
convert_options([_ | R]) -> %% skip unknown option
    convert_options(R).


get_checkpoint_log_id(#db{name = DbName0}, LogId0) ->
    get_checkpoint_log_id(?b2l(DbName0), LogId0);
get_checkpoint_log_id(#httpdb{url = DbUrl0}, LogId0) ->
    [_, _, DbName0] = string:tokens(DbUrl0, "/"),
    get_checkpoint_log_id(couch_httpd:unquote(DbName0), LogId0);
get_checkpoint_log_id(DbName0, LogId0) ->
    {DbName, _UUID} = split_uuid(DbName0),
    {_, VBucket} = split_dbname(DbName),
    ?l2b([?LOCAL_DOC_PREFIX, integer_to_list(VBucket), "-", LogId0]).

get_master_db(#db{name = DbName}) ->
    ?l2b(get_master_db(?b2l(DbName)));
get_master_db(#httpdb{url=DbUrl0}=Http) ->
    [Scheme, Host, DbName0] = string:tokens(DbUrl0, "/"),
    DbName = get_master_db(couch_httpd:unquote(DbName0)),

    DbUrl = Scheme ++ "//" ++ Host ++ "/" ++ couch_httpd:quote(DbName) ++ "/",
    Http#httpdb{url = DbUrl, httpc_pool = nil};
get_master_db(DbName0) ->
    {DbName, UUID} = split_uuid(DbName0),
    {Bucket, _} = split_dbname(DbName),
    MasterDbName = Bucket ++ "/master",
    unsplit_uuid({MasterDbName, UUID}).

split_dbname(DbName) ->
    %% couchbase does not support slashes in bucket names; thus we can have only
    %% two items in this list
    [BucketName, VBucketStr] = string:tokens(DbName, [$/]),
    {BucketName, list_to_integer(VBucketStr)}.

split_uuid(DbName) ->
    case string:tokens(DbName, [$;]) of
        [RealDbName, UUID] ->
            {RealDbName, UUID};
        _ ->
            {DbName, undefined}
    end.

unsplit_uuid({DbName, undefined}) ->
    DbName;
unsplit_uuid({DbName, UUID}) ->
    DbName ++ ";" ++ UUID.

-spec get_opt_replication_threshold() -> integer().
get_opt_replication_threshold() ->
    {value, DefaultOptRepThreshold} = ns_config:search(xdcr_optimistic_replication_threshold),
    Threshold = misc:getenv_int("XDCR_OPTIMISTIC_REPLICATION_THRESHOLD", DefaultOptRepThreshold),

    case Threshold of
        V when V < 0 ->
            0;
        _ ->
            Threshold
    end.

%% get xdc replication options, log them if changed
-spec update_options(list()) -> list().
update_options(Options) ->
    Threshold = get_opt_replication_threshold(),
    case length(Options) > 0 andalso Threshold =/= get_value(opt_rep_threshold, Options) of
        true ->
            ?xdcr_debug("XDC parameter changed, opt_rep_threshold is updated from ~p to ~p",
                       [get_value(opt_rep_threshold, Options) , Threshold]);
        _ ->
            ok
    end,

    {value, DefaultWorkerBatchSize} = ns_config:search(xdcr_worker_batch_size),
    DefBatchSize = misc:getenv_int("XDCR_WORKER_BATCH_SIZE", DefaultWorkerBatchSize),
    case length(Options) > 0 andalso DefBatchSize =/= get_value(worker_batch_size, Options) of
        true ->
            ?xdcr_debug("XDC parameter changed, worker_batch_size is updated from ~p to ~p",
                       [get_value(worker_batch_size, Options) , DefBatchSize]);
        _ ->
            ok
    end,

    {value, DefaultConnTimeout} = ns_config:search(xdcr_connection_timeout),
    DefTimeoutSecs = misc:getenv_int("XDCR_CONNECTION_TIMEOUT", DefaultConnTimeout),
    %% convert to ms
    DefTimeout = 1000*DefTimeoutSecs,
    case length(Options) > 0 andalso DefTimeout =/= get_value(connection_timeout, Options) of
        true ->
            ?xdcr_debug("XDC parameter changed, connection_timeout is updated from ~p to ~p",
                       [get_value(connection_timeout, Options) , DefTimeout]);
        _ ->
            ok
    end,

    {value, DefaultWorkers} = ns_config:search(xdcr_num_worker_process),
    DefWorkers = misc:getenv_int("XDCR_NUM_WORKER_PROCESS", DefaultWorkers),
    case length(Options) > 0 andalso DefWorkers =/= get_value(worker_processes, Options) of
        true ->
            ?xdcr_debug("XDC parameter changed, num_worker_process is updated from ~p to ~p",
                       [get_value(worker_processes, Options) , DefWorkers]);
        _ ->
            ok
    end,

    {value, DefaultConns} = ns_config:search(xdcr_num_http_connections),
    DefConns = misc:getenv_int("XDCR_NUM_HTTP_CONNECTIONS", DefaultConns),
    case length(Options) > 0 andalso DefConns =/= get_value(http_connections, Options) of
        true ->
            ?xdcr_debug("XDC parameter changed, http_connections is updated from ~p to ~p",
                       [get_value(http_connections, Options) , DefConns]);
        _ ->
            ok
    end,


    {value, DefaultRetries} = ns_config:search(xdcr_num_retries_per_request),
    DefRetries = misc:getenv_int("XDCR_NUM_RETRIES_PER_REQUEST", DefaultRetries),
    case length(Options) > 0 andalso DefRetries =/= get_value(retries, Options) of
        true ->
            ?xdcr_debug("XDC parameter changed, num_retries_per_request is updated from ~p to ~p",
                       [get_value(retries, Options) , DefRetries]);
        _ ->
            ok
    end,

    %% update option list
    lists:ukeymerge(1, lists:keysort(1, [
                      {connection_timeout, DefTimeout},
                      {retries, DefRetries},
                      {http_connections, DefConns},
                      {worker_batch_size, DefBatchSize},
                      {worker_processes, DefWorkers},
                      {opt_rep_threshold, Threshold}]), Options).

-spec get_replication_mode() -> list().
get_replication_mode() ->
    EnvVar = case (catch string:to_lower(os:getenv("XDCR_REPLICATION_MODE"))) of
                 "capi" ->
                     "capi";
                 "xmem" ->
                     "xmem";
                 _ ->
                     undefined
             end,

    %% env var overrides ns_config parameter, use default ns_config parameter
    %% only when env var is undefined
    case EnvVar of
        undefined ->
            case ns_config:search(xdcr_replication_mode) of
                {value, DefaultRepMode} ->
                    DefaultRepMode;
                false ->
                    "capi"
            end;
        _ ->
            EnvVar
    end.

-spec get_replication_batch_size() -> integer().
get_replication_batch_size() ->
    %% env parameter can override the ns_config parameter
    {value, DefaultDocBatchSizeKB} = ns_config:search(xdcr_doc_batch_size_kb),
    DocBatchSizeKB = misc:getenv_int("XDCR_DOC_BATCH_SIZE_KB", DefaultDocBatchSizeKB),
    1024*DocBatchSizeKB.

-spec is_pipeline_enabled() -> boolean().
is_pipeline_enabled() ->
    %% env parameter can override the ns_config parameter
    {value, EnablePipeline} = ns_config:search(xdcr_enable_pipeline_ops),
    case os:getenv("XDCR_ENABLE_PIPELINE") of
        "true" ->
            true;
        "false" ->
            false;
        _ ->
            EnablePipeline
    end.

%% inverse probability to dump non-critical datapath trace,
%% trace will be dumped by probability 1/N
-spec get_trace_dump_invprob() -> integer().
get_trace_dump_invprob() ->
    %% env parameter can override the ns_config parameter
    {value, DefInvProb} = ns_config:search(xdcr_trace_dump_inverse_prob),
    misc:getenv_int("XDCR_TRACE_DUMP_INVERSE_PROB", DefInvProb).

-spec get_xmem_worker() -> integer().
get_xmem_worker() ->
    %% env parameter can override the ns_config parameter
    {value, DefNumXMemWorker} = ns_config:search(xdcr_xmem_worker),
    misc:getenv_int("XDCR_XMEM_WORKER", DefNumXMemWorker).

-spec is_local_conflict_resolution() -> boolean().
is_local_conflict_resolution() ->
    case ns_config:search(xdcr_local_conflict_resolution) of
        {value, LocalConflictRes} ->
            LocalConflictRes;
        false ->
            false
    end.

-spec get_checkpoint_mode() -> list().
get_checkpoint_mode() ->
    %% always checkpoint to remote capi unless specified by env parameter
    case (catch string:to_lower(os:getenv("XDCR_CHECKPOINT_MODE"))) of
        "xmem" ->
            ?xdcr_debug("Warning! Different from default CAPI checkpoint, "
                        "we checkpoint to memcached", []),
            "xmem";
        _ ->
            "capi"
    end.

sanitize_url(Url) when is_binary(Url) ->
    ?l2b(sanitize_url(?b2l(Url)));
sanitize_url(Url) when is_list(Url) ->
    I = string:rchr(Url, $@),
    case I of
        0 ->
            Url;
        _ ->
            "*****" ++ string:sub_string(Url, I)
    end;
sanitize_url(Url) ->
    Url.

sanitize_state(State) ->
    misc:rewrite_tuples(fun (T) ->
                                case T of
                                    #xdc_rep_xmem_remote{} = Remote ->
                                        {stop, Remote#xdc_rep_xmem_remote{password = "*****"}};
                                    #rep_state{} = RepState ->
                                        {continue,
                                         RepState#rep_state{target_name = sanitize_url(RepState#rep_state.target_name)}};
                                    #httpdb{} = HttpDb ->
                                        {stop,
                                         HttpDb#httpdb{url = sanitize_url(HttpDb#httpdb.url)}};
                                    _ ->
                                        {continue, T}
                                end
                        end, State).

sanitize_status(_Opt, _PDict, State) ->
    [{data, [{"State", sanitize_state(State)}]}].

