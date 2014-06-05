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
-export([split_bucket_name_out_of_target_url/1]).
-export([local_couch_uri_for_vbucket/2]).
-export([my_active_vbuckets/1]).
-export([parse_rep_db/3]).
-export([sanitize_status/3, get_rep_info/1]).
-export([is_new_xdcr_path/0]).

-include("xdc_replicator.hrl").

%% imported functions
-import(couch_util, [get_value/2,
                     get_value/3]).

%% Given a Bucket name and a vbucket id, this function computes the Couch URI to
%% locally access it.
local_couch_uri_for_vbucket(BucketName, VbucketId) ->
    iolist_to_binary([BucketName, $/, integer_to_list(VbucketId)]).

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
    Options = xdc_settings:get_all_settings_snapshot(Props),
    Source = parse_rep_db(get_value(<<"source">>, Props), ProxyParams, Options),
    Target = parse_rep_db(get_value(<<"target">>, Props), ProxyParams, Options),
    RepMode = case get_value(<<"type">>, Props) of
                  <<"xdc">> ->
                      "capi";
                  <<"xdc-xmem">> ->
                      "xmem"
              end,
    #rep{id = DocId,
         source = Source,
         target = Target,
         replication_mode = RepMode,
         options = Options}.

parse_proxy_params(ProxyUrl) when is_binary(ProxyUrl) ->
    parse_proxy_params(?b2l(ProxyUrl));
parse_proxy_params([]) ->
    [];
parse_proxy_params(ProxyUrl) ->
    [{proxy, ProxyUrl}].

parse_rep_db({Props}, _ProxyParams, Options) ->
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
    SslParams = case Url of
                    "http://" ++ _ ->
                        [];
                    "https://" ++ _ ->
                        %% we cannot allow https without cert. If cert
                        %% is missing, requests must not go through
                        %% (undefined will cause crash in call below)
                        CertPEM = get_value(xdcr_cert, Options, undefined),
                        ns_ssl:cert_pem_to_ssl_verify_options(CertPEM)
                end,
    ConnectOpts = get_value(socket_options, Options) ++ SslParams,
    Timeout = get_value(connection_timeout, Options) * 1000,
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
             httpc_pool = xdc_lhttpc_pool,
             http_connections = get_value(http_connections, Options),
             retries = get_value(retries_per_request, Options)
           };
parse_rep_db(<<"http://", _/binary>> = Url, ProxyParams, Options) ->
    parse_rep_db({[{<<"url">>, Url}]}, ProxyParams, Options);
parse_rep_db(<<"https://", _/binary>> = Url, ProxyParams, Options) ->
    parse_rep_db({[{<<"url">>, Url}]}, ProxyParams, Options);
parse_rep_db(<<DbName/binary>>, _ProxyParams, _Options) ->
    DbName.

maybe_add_trailing_slash(Url) when is_binary(Url) ->
    maybe_add_trailing_slash(?b2l(Url));
maybe_add_trailing_slash(Url) ->
    case lists:last(Url) of
        $/ ->
            Url;
        _ ->
            Url ++ "/"
    end.

split_bucket_name_out_of_target_url(Url) ->
    [Scheme, Host, DbName0] = string:tokens(couch_util:to_list(Url), "/"),
    DbName = couch_httpd:unquote(DbName0),
    {RawDbName, UUID} = split_uuid(DbName),
    [BucketName, VBString] = string:tokens(RawDbName, "/"),
    {Scheme ++ "//" ++ Host ++ "/", BucketName, UUID, VBString}.

split_uuid(DbName) ->
    case string:tokens(DbName, [$;]) of
        [RealDbName, UUID] ->
            {RealDbName, UUID};
        _ ->
            {DbName, undefined}
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
                                    #xdc_xmem_location{} = Location ->
                                        {stop,
                                         Location#xdc_xmem_location{mcd_loc = "*****"}};
                                    _ ->
                                        {continue, T}
                                end
                        end, State).

sanitize_status(_Opt, _PDict, State) ->
    [{data, [{"State", sanitize_state(State)}]}].

get_rep_info(#rep{source = Src, target = Tgt, replication_mode = Mode}) ->
    ?format_msg("from ~p to ~p in mode: ~p", [Src, Tgt, Mode]).


is_new_xdcr_path() ->
    ns_config:read_key_fast(xdcr_use_new_path, false).
