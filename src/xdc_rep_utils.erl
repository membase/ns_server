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
-export([parse_rep_db/1]).
-export([split_dbname/1]).
-export([get_master_db/1, get_checkpoint_log_id/2]).

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

parse_rep_db(Db) ->
    Options = make_options([]),
    parse_rep_db(Db, [], Options).

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
    DefWorkers = couch_config:get("replicator", "worker_processes", "1"),
    DefBatchSize = couch_config:get("replicator", "worker_batch_size", "500"),
    DefConns = couch_config:get("replicator", "http_connections", "10"),
    DefTimeout = couch_config:get("replicator", "connection_timeout", "30000"),
    DefRetries = couch_config:get("replicator", "retries_per_request", "10"),
    DefRepModeStr = couch_config:get("replicator", "continuous", "false"),
    DefRepMode = case DefRepModeStr of
                     "true" ->
                         true;
                     _ ->
                         false
                 end,

    {ok, DefSocketOptions} = couch_util:parse_term(
                               couch_config:get("replicator", "socket_options",
                                                "[{keepalive, true}, {nodelay, false}]")),

    ?xdcr_debug("Options for replication from couch_config:["
               "worker processes: ~s, "
               "worker batch size: ~s, "
               "HTTP connections: ~s, "
               "connection timeout: ~s]",
               [DefWorkers, DefBatchSize, DefConns, DefTimeout]),

    lists:ukeymerge(1, Options, lists:keysort(1, [
                                                  {connection_timeout, list_to_integer(DefTimeout)},
                                                  {retries, list_to_integer(DefRetries)},
                                                  {continuous, DefRepMode},
                                                  {http_connections, list_to_integer(DefConns)},
                                                  {socket_options, DefSocketOptions},
                                                  {worker_batch_size, list_to_integer(DefBatchSize)},
                                                  {worker_processes, list_to_integer(DefWorkers)}
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
convert_options([{<<"cancel">>, V} | R]) ->
    [{cancel, V} | convert_options(R)];
convert_options([{IdOpt, V} | R]) when IdOpt =:= <<"_local_id">>;
                                       IdOpt =:= <<"replication_id">>; IdOpt =:= <<"id">> ->
    Id = lists:splitwith(fun(X) -> X =/= $+ end, ?b2l(V)),
    [{id, Id} | convert_options(R)];
convert_options([{<<"create_target">>, V} | R]) ->
    [{create_target, V} | convert_options(R)];
convert_options([{<<"continuous">>, V} | R]) ->
    [{continuous, V} | convert_options(R)];
convert_options([{<<"query_params">>, V} | R]) ->
    [{query_params, V} | convert_options(R)];
convert_options([{<<"doc_ids">>, V} | R]) ->
    %% Ensure same behaviour as old replicator: accept a list of percent
    %% encoded doc IDs.
    DocIds = [?l2b(couch_httpd:unquote(Id)) || Id <- V],
    [{doc_ids, DocIds} | convert_options(R)];
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
convert_options([{<<"since_seq">>, V} | R]) ->
    [{since_seq, V} | convert_options(R)];
convert_options([_ | R]) -> %% skip unknown option
    convert_options(R).


get_checkpoint_log_id(#db{name = DbName0}, LogId0) ->
    get_checkpoint_log_id(?b2l(DbName0), LogId0);
get_checkpoint_log_id(#httpdb{url = DbUrl0}, LogId0) ->
    [_, _, DbName0] = [couch_httpd:unquote(Token) ||
                          Token <- string:tokens(DbUrl0, "/")],
    get_checkpoint_log_id(mochiweb_util:unquote(DbName0), LogId0);
get_checkpoint_log_id(DbName0, LogId0) ->
    {DbName, _UUID} = split_uuid(DbName0),
    {_, VBucket} = split_dbname(DbName),
    ?l2b([?LOCAL_DOC_PREFIX, integer_to_list(VBucket), "-", LogId0]).

get_master_db(#db{name = DbName}) ->
    ?l2b(get_master_db(?b2l(DbName)));
get_master_db(#httpdb{url=DbUrl0}=Http) ->
    [Scheme, Host, DbName0] = [couch_httpd:unquote(Token) ||
                                  Token <- string:tokens(DbUrl0, "/")],
    DbName = get_master_db(DbName0),

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
