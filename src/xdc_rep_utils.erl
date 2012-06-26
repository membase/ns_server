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

-export([parse_rep_doc/2, is_valid_xdc_rep_doc/1]).
-export([remote_vbucketmap_nodelist/1, local_couch_uri_for_vbucket/2]).
-export([remote_couch_uri_for_vbucket/3, my_active_vbuckets/1]).
-export([lists_difference/2, node_uuid/0, info_doc_id/1, vb_rep_state_list/2]).
-export([replication_id/2]).
-export([sum_stats/2]).
-export([split_dbname/1]).
-export([get_master_db/1, get_checkpoint_log_id/2]).

-include("xdc_replicator.hrl").

%% Given a remote bucket URI, this function fetches the node list and the vbucket
%% map.
remote_vbucketmap_nodelist(BucketURI) ->
    case httpc:request(get, {BucketURI, []}, [], []) of
        {ok, {{_, 404, _}, _, _}} ->
            not_present;
        {ok, {_, _, JsonStr}} ->
            {KVList} = ejson:decode(JsonStr),
            {VbucketServerMap} = couch_util:get_value(<<"vBucketServerMap">>,
                                                      KVList),
            VbucketMap = couch_util:get_value(<<"vBucketMap">>, VbucketServerMap),
            ServerList = couch_util:get_value(<<"serverList">>, VbucketServerMap),
            NodeList = couch_util:get_value(<<"nodes">>, KVList),

            %% We purposefully mangle the order of the elements of the <<"nodes">>
            %% list -- presumably to achieve better load balancing by not letting
            %% unmindful clients always target nodes at the same ordinal position in
            %% the list.
            %%
            %% The code below imposes a consistent ordering of the nodes w.r.t. the
            %% vbucket map. In order to be efficient, we first build a dictionary
            %% out of the node list elements so that lookups are cheaper later while
            %% reordering them.
            NodeDict = dict:from_list(
                         lists:map(
                           fun({Props} = Node) ->
                                   [Hostname, _] =
                                       string:tokens(?b2l(
                                                        couch_util:get_value(<<"hostname">>, Props)), ":"),
                                   {Ports} = couch_util:get_value(<<"ports">>, Props),
                                   DirectPort = couch_util:get_value(<<"direct">>, Ports),
                                   {?l2b(Hostname ++ ":" ++ integer_to_list(DirectPort)), Node}
                           end,
                           NodeList)),
            OrderedNodeList =
                lists:map(
                  fun(Server) ->
                          dict:fetch(Server, NodeDict)
                  end,
                  ServerList),

            {ok, {VbucketMap, OrderedNodeList}}
    end.


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


%% Computes the differences between two lists and returns them as a tuple.
lists_difference(List1, List2) ->
    {List1 -- List2, List2 -- List1}.


%% Fetches the UUID of the current node.
node_uuid() ->
    {value, UUID} = ns_config:search_node(uuid),
    UUID.


%% Given an XDC doc id, this function generates the correspondence replication
%% info doc id.
info_doc_id(XDocId) ->
    UUID = node_uuid(),
    <<XDocId/binary, "_info_", UUID/binary>>.


%% Generate a list of tuples corresponding to the given list of vbucket ids. Each
%% tuple consists of the "replication_state_vb_" tag for a vbucket id in the list
%% and the given replication state value.
vb_rep_state_list(VbList, RepState) ->
    lists:map(
      fun(Vb) ->
              {?l2b("replication_state_vb_" ++ ?i2l(Vb)), <<RepState/binary>>}
      end,
      VbList).

%% Parse replication document
parse_rep_doc({Props}, UserCtx) ->
    ProxyParams = parse_proxy_params(get_value(<<"proxy">>, Props, <<>>)),
    Options = make_options(Props),
    case get_value(cancel, Options, false) andalso
        (get_value(id, Options, nil) =/= nil) of
        true ->
            {ok, #rep{options = Options, user_ctx = UserCtx}};
        false ->
            Source = parse_rep_db(get_value(<<"source">>, Props), ProxyParams, Options),
            Target = parse_rep_db(get_value(<<"target">>, Props), ProxyParams, Options),
            Rep = #rep{
              source = Source,
              target = Target,
              options = Options,
              user_ctx = UserCtx,
              doc_id = get_value(<<"_id">>, Props)
             },
            {ok, Rep#rep{id = replication_id(Rep)}}
    end.

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
    lists:ukeymerge(1, Options, lists:keysort(1, [
                                                  {connection_timeout, list_to_integer(DefTimeout)},
                                                  {retries, list_to_integer(DefRetries)},
                                                  {continuous, DefRepMode},
                                                  {http_connections, list_to_integer(DefConns)},
                                                  {socket_options, DefSocketOptions},
                                                  {worker_batch_size, list_to_integer(DefBatchSize)},
                                                  {worker_processes, list_to_integer(DefWorkers)}
                                                 ])).


replication_id(#rep{options = Options} = Rep) ->
    BaseId = replication_id(Rep, ?REP_ID_VERSION),
    {BaseId, maybe_append_options([continuous, create_target], Options)}.



%% Versioned clauses for generating replication IDs.
%% If a change is made to how replications are identified,
%% please add a new clause and increase ?REP_ID_VERSION.

replication_id(#rep{user_ctx = UserCtx} = Rep, 2) ->
    {ok, HostName} = inet:gethostname(),
    Port = case (catch mochiweb_socket_server:get(couch_httpd, port)) of
               P when is_number(P) ->
                   P;
               _ ->
                   %% On restart we might be called before the couch_httpd process is
                   %% started.
                   %% TODO: we might be under an SSL socket server only, or both under
                   %% SSL and a non-SSL socket.
                   %% ... mochiweb_socket_server:get(https, port)
                   list_to_integer(couch_config:get("httpd", "port", "5984"))
           end,
    Src = get_rep_endpoint(UserCtx, Rep#rep.source),
    Tgt = get_rep_endpoint(UserCtx, Rep#rep.target),
    maybe_append_filters([HostName, Port, Src, Tgt], Rep);

replication_id(#rep{user_ctx = UserCtx} = Rep, 1) ->
    {ok, HostName} = inet:gethostname(),
    Src = get_rep_endpoint(UserCtx, Rep#rep.source),
    Tgt = get_rep_endpoint(UserCtx, Rep#rep.target),
    maybe_append_filters([HostName, Src, Tgt], Rep).


maybe_add_trailing_slash(Url) when is_binary(Url) ->
    maybe_add_trailing_slash(?b2l(Url));
maybe_add_trailing_slash(Url) ->
    case lists:last(Url) of
        $/ ->
            Url;
        _ ->
            Url ++ "/"
    end.


maybe_append_options(Options, RepOptions) ->
    lists:foldl(fun(Option, Acc) ->
                        Acc ++
                            case get_value(Option, RepOptions, false) of
                                true ->
                                    "+" ++ atom_to_list(Option);
                                false ->
                                    ""
                            end
                end, [], Options).



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
convert_options([{<<"filter">>, V} | R]) ->
    [{filter, V} | convert_options(R)];
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



get_rep_endpoint(_UserCtx, #httpdb{url=Url, headers=Headers, oauth=OAuth}) ->
    DefaultHeaders = (#httpdb{})#httpdb.headers,
    case OAuth of
        nil ->
            {remote, Url, Headers -- DefaultHeaders};
        #oauth{} ->
            {remote, Url, Headers -- DefaultHeaders, OAuth}
    end;
get_rep_endpoint(UserCtx, <<DbName/binary>>) ->
    {local, DbName, UserCtx}.


maybe_append_filters(Base,
                     #rep{source = Source, user_ctx = UserCtx, options = Options}) ->
    Base2 = Base ++
        case get_value(filter, Options) of
            undefined ->
                case get_value(doc_ids, Options) of
                    undefined ->
                        [];
                    DocIds ->
                        [DocIds]
                end;
            Filter ->
                [filter_code(Filter, Source, UserCtx),
                 get_value(query_params, Options, {[]})]
        end,
    couch_util:to_hex(couch_util:md5(term_to_binary(Base2))).


filter_code(Filter, Source, UserCtx) ->
    {DDocName, FilterName} =
        case re:run(Filter, "(.*?)/(.*)", [{capture, [1, 2], binary}]) of
            {match, [DDocName0, FilterName0]} ->
                {DDocName0, FilterName0};
            _ ->
                throw({error, <<"Invalid filter. Must match `ddocname/filtername`.">>})
        end,
    Db = case (catch couch_api_wrap:db_open(Source, [{user_ctx, UserCtx}])) of
             {ok, Db0} ->
                 Db0;
             DbError ->
                 DbErrorMsg = io_lib:format("Could not open source database `~s`: ~s",
                                            [couch_api_wrap:db_uri(Source), couch_util:to_binary(DbError)]),
                 throw({error, iolist_to_binary(DbErrorMsg)})
         end,
    try
        Body = case (catch couch_api_wrap:open_doc(
                             Db, <<"_design/", DDocName/binary>>, [ejson_body])) of
                   {ok, #doc{body = Body0}} ->
                       Body0;
                   DocError ->
                       DocErrorMsg = io_lib:format(
                                       "Couldn't open document `_design/~s` from source "
                                       "database `~s`: ~s", [DDocName, couch_api_wrap:db_uri(Source),
                                                             couch_util:to_binary(DocError)]),
                       throw({error, iolist_to_binary(DocErrorMsg)})
               end,
        Code = couch_util:get_nested_json_value(
                 Body, [<<"filters">>, FilterName]),
        re:replace(Code, [$^, "\s*(.*?)\s*", $$], "\\1", [{return, binary}])
    after
        couch_api_wrap:db_close(Db)
    end.


%% FIXME: Add useful sanity checks to ensure we have a valid replication doc
is_valid_xdc_rep_doc(_RepDoc) ->
    true.

sum_stats(#rep_stats{} = S1, #rep_stats{} = S2) ->
    #rep_stats{
           missing_checked =
               S1#rep_stats.missing_checked + S2#rep_stats.missing_checked,
           missing_found = S1#rep_stats.missing_found + S2#rep_stats.missing_found,
           docs_read = S1#rep_stats.docs_read + S2#rep_stats.docs_read,
           docs_written = S1#rep_stats.docs_written + S2#rep_stats.docs_written,
           doc_write_failures =
               S1#rep_stats.doc_write_failures + S2#rep_stats.doc_write_failures
          }.


get_checkpoint_log_id(#db{name = DbName0}, LogId0) ->
    get_checkpoint_log_id(DbName0, LogId0);
get_checkpoint_log_id(#httpdb{url = DbUrl0}, LogId0) ->
    [_, _, DbName0] = [couch_httpd:unquote(Token) ||
                          Token <- string:tokens(DbUrl0, "/")],
    get_checkpoint_log_id(?l2b(DbName0), LogId0);
get_checkpoint_log_id(DbName0, LogId0) ->
    {_, VBucket} = split_dbname(DbName0),
    ?l2b([?LOCAL_DOC_PREFIX, integer_to_list(VBucket), "-", LogId0]).

get_master_db(#db{name = DbName0}) ->
    get_master_db(DbName0);
get_master_db(#httpdb{url=DbUrl0}) ->
    [Scheme, Host, DbName0] = [couch_httpd:unquote(Token) ||
                                  Token <- string:tokens(DbUrl0, "/")],
    DbName = get_master_db(?l2b(DbName0)),
    DbUrl = Scheme ++ "//" ++ Host ++ "/" ++ couch_httpd:quote(DbName) ++ "/",
    #httpdb{url = DbUrl, timeout = 300000};
get_master_db(DbName0) ->
    {Bucket, _} = split_dbname(DbName0),
    iolist_to_binary([Bucket, $/, <<"master">>]).

split_dbname(DbName) ->
    DbNameStr = binary_to_list(DbName),
    Tokens = string:tokens(DbNameStr, [$/]),
    build_info(Tokens, []).

build_info([VBucketStr], R) ->
    {lists:append(lists:reverse(R)), list_to_integer(VBucketStr)};
build_info([H|T], R)->
    build_info(T, [H|R]).

