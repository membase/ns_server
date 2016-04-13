%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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

-module(ns_server_cert).

-include("ns_common.hrl").

-include_lib("public_key/include/public_key.hrl").

-export([do_generate_cert_and_pkey/2,
         validate_cert/1,
         generate_and_set_cert_and_pkey/0,
         cluster_ca/0,
         set_cluster_ca/1,
         apply_certificate_chain_from_inbox/0,
         apply_certificate_chain_from_inbox/1,
         get_warnings/1,
         get_node_cert_info/1]).

inbox_chain_path() ->
    filename:join(path_config:component_path(data, "inbox"), "chain.pem").

inbox_pkey_path() ->
    filename:join(path_config:component_path(data, "inbox"), "pkey.pem").

cluster_ca() ->
    case ns_config:search(cert_and_pkey) of
        {value, Tuple} ->
            Tuple;
        false ->
            Pair = generate_cert_and_pkey(),
            RV = ns_config:run_txn(
                   fun (Config, SetFn) ->
                           case ns_config:search(Config, cert_and_pkey) of
                               {value, OtherPair} ->
                                   {abort, OtherPair};
                               false ->
                                   {commit, SetFn(cert_and_pkey, Pair, Config)}
                           end
                   end),

            case RV of
                {abort, OtherPair} ->
                    OtherPair;
                _ ->
                    Pair
            end
    end.

generate_and_set_cert_and_pkey() ->
    Pair = generate_cert_and_pkey(),
    ns_config:set(cert_and_pkey, Pair).

generate_cert_and_pkey() ->
    StartTS = os:timestamp(),
    Args = case ns_config:read_key_fast({cert, use_sha1}, false) of
               true ->
                   ["--use-sha1"];
               false ->
                   []
           end,
    RV = do_generate_cert_and_pkey(Args, []),
    EndTS = os:timestamp(),

    Diff = timer:now_diff(EndTS, StartTS),
    ?log_debug("Generated certificate and private key in ~p us", [Diff]),

    RV.

do_generate_cert_and_pkey(Args, Env) ->
    {Status, Output} = misc:run_external_tool(path_config:component_path(bin, "generate_cert"), Args, Env),
    case Status of
        0 ->
            extract_cert_and_pkey(Output);
        _ ->
            erlang:exit({bad_generate_cert_exit, Status, Output})
    end.


validate_cert(CertPemBin) ->
    PemEntries = public_key:pem_decode(CertPemBin),
    NonCertEntries = [Type || {Type, _, _} <- PemEntries,
                              Type =/= 'Certificate'],
    case NonCertEntries of
        [] ->
            {ok, PemEntries};
        _ ->
            {error, non_cert_entries, NonCertEntries}
    end.

validate_pkey(PKeyPemBin) ->
    %% TODO: validate pkey with cert public key
    [Entry] = public_key:pem_decode(PKeyPemBin),
    case Entry of
        {'RSAPrivateKey', _, _} ->
            ok;
        {'DSAPrivateKey', _, _} ->
            ok;
        {'PrivateKeyInfo', _, _} ->
            ok;
        {BadType, _, _} ->
            {error, invalid_pkey, BadType}
    end.

extract_cert_and_pkey(Output) ->
    Begin = <<"-----BEGIN">>,
    [<<>> | Parts0] = binary:split(Output, Begin, [global]),
    Parts = [<<Begin/binary,P/binary>> || P <- Parts0],
    %% we're anticipating chain of certs and pkey here
    [PKey | CertParts] = lists:reverse(Parts),
    Cert = iolist_to_binary(lists:reverse(CertParts)),
    ValidateCertErr = case validate_cert(Cert) of
                          {ok, _} -> ok;
                          Err -> Err
                      end,
    Results = [ValidateCertErr, validate_pkey(PKey)],
    BadResults = [Err || Err <- Results,
                         Err =/= ok],
    case BadResults of
        [] ->
            ok;
        _ ->
            erlang:exit({bad_cert_or_pkey, BadResults})
    end,
    {Cert, PKey}.

attribute_string(?'id-at-countryName') ->
    "C";
attribute_string(?'id-at-stateOrProvinceName') ->
    "ST";
attribute_string(?'id-at-localityName') ->
    "L";
attribute_string(?'id-at-organizationName') ->
    "O";
attribute_string(?'id-at-commonName') ->
    "CN";
attribute_string(_) ->
    undefined.

format_attribute([#'AttributeTypeAndValue'{type = Type,
                                           value = Value}], Acc) ->
    case attribute_string(Type) of
        undefined ->
            Acc;
        Str ->
            [[Str, "=", format_value(Value)] | Acc]
    end.

format_value({utf8String, Utf8Value}) ->
    unicode:characters_to_list(Utf8Value);
format_value({_, Value}) when is_list(Value) ->
    Value;
format_value(Value) when is_list(Value) ->
    Value;
format_value(Value) ->
    io_lib:format("~p", [Value]).

format_name({rdnSequence, STVList}) ->
    Attributes = lists:foldl(fun format_attribute/2, [], STVList),
    lists:flatten(string:join(lists:reverse(Attributes), ", ")).

convert_date(Year, Rest) ->
    {ok, [Month, Day, Hour, Min, Sec], "Z"} = io_lib:fread("~2d~2d~2d~2d~2d", Rest),
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {Hour, Min, Sec}}).

convert_date({utcTime, [Y1, Y2 | Rest]}) ->
    Year = list_to_integer([Y1, Y2]) + 2000,
    convert_date(Year, Rest);
convert_date({generalTime, [Y1, Y2, Y3, Y4 | Rest]}) ->
    Year = list_to_integer([Y1, Y2, Y3, Y4]),
    convert_date(Year, Rest).

get_info(DerCert) ->
    Decoded = public_key:pkix_decode_cert(DerCert, otp),
    TBSCert = Decoded#'OTPCertificate'.tbsCertificate,
    Subject = format_name(TBSCert#'OTPTBSCertificate'.subject),

    Validity = TBSCert#'OTPTBSCertificate'.validity,
    NotBefore = convert_date(Validity#'Validity'.notBefore),
    NotAfter = convert_date(Validity#'Validity'.notAfter),
    {Subject, NotBefore, NotAfter}.

parse_cluster_ca(CA) ->
    case validate_cert(CA) of
        {ok, []} ->
            {error, malformed_cert, CA};
        {ok, [{'Certificate', RootCertDer, not_encrypted}]} ->
            Info =
                try
                    get_info(RootCertDer)
                catch T:E ->
                        {error, malformed_cert, {T,E,erlang:get_stacktrace()}}
                end,
            case Info of
                {error, malformed_cert, _} = E1 ->
                    E1;
                {Subject, NotBefore, NotAfter} ->
                    UTC = calendar:datetime_to_gregorian_seconds(
                            calendar:universal_time()),
                    case NotBefore > UTC orelse NotAfter < UTC of
                        true ->
                            {error, not_valid_at_this_time, [{now, UTC}, Info]};
                        false ->
                            {ok, [{pem, CA},
                                  {subject, Subject},
                                  {expires, NotAfter}]}
                    end
            end;
        {ok, OtherList} ->
            {error, too_many_entries, OtherList};
        Error ->
            Error
    end.

set_cluster_ca(CA) ->
    case parse_cluster_ca(CA) of
        {ok, Props} ->
            RV = ns_config:run_txn(
                   fun (Config, SetFn) ->
                           {GeneratedCert, GeneratedKey} =
                               case ns_config:search(Config, cert_and_pkey) of
                                   {value, {_, _} = Pair} ->
                                       Pair;
                                   {value, {_, GeneratedCert1, GeneratedKey1}} ->
                                       {GeneratedCert1, GeneratedKey1};
                                   false ->
                                       generate_cert_and_pkey()
                               end,
                           {commit, SetFn(cert_and_pkey,
                                          {Props, GeneratedCert, GeneratedKey}, Config)}
                   end),
            case RV of
                {commit, _} ->
                    {ok, Props};
                retry_needed ->
                    erlang:error(exceeded_retries)
            end;
        {error, Error, _} = Err ->
            ?log_error("Certificate authority validation failed with ~p", [Err]),
            {error, Error}
    end.

verify_fun(Cert, Event, State) ->
    TBSCert = Cert#'OTPCertificate'.tbsCertificate,
    Subject = format_name(TBSCert#'OTPTBSCertificate'.subject),
    ?log_debug("Certificate verification event : ~p", [{Subject, Event}]),

    case Event of
        {bad_cert, Error} ->
            ?log_error("Certificate ~p validation failed with reason ~p",
                       [Subject, Error]),
            {fail, {Error, Subject}};
        {extension, _} ->
            {unknown, State};
        valid ->
            {valid, State};
        valid_peer ->
            {valid, State}
    end.

validate_chain({'Certificate', RootCertDer, not_encrypted}, Chain) ->
    DerChain = [Der || {'Certificate', Der, not_encrypted} <- Chain],
    public_key:pkix_path_validation(RootCertDer, DerChain, [{verify_fun, {fun verify_fun/3, []}}]).

get_chain_info(Chain) ->
    lists:foldl(fun ({'Certificate', DerCert, not_encrypted}, Acc) ->
                        Decoded = public_key:pkix_decode_cert(DerCert, otp),
                        TBSCert = Decoded#'OTPCertificate'.tbsCertificate,
                        Validity = TBSCert#'OTPTBSCertificate'.validity,
                        NotAfter = convert_date(Validity#'Validity'.notAfter),
                        case Acc of
                            undefined ->
                                {format_name(TBSCert#'OTPTBSCertificate'.subject), NotAfter};
                            {Sub, Expiration} when Expiration > NotAfter  ->
                                {Sub, NotAfter};
                            Pair ->
                                Pair
                        end
                end, undefined, lists:reverse(Chain)).

set_node_certificate_chain(ClusterCA, Chain, PKey) ->
    [CAPemEntry] = public_key:pem_decode(ClusterCA),
    PemEntriesReversed = lists:reverse(public_key:pem_decode(Chain)),

    case validate_chain(CAPemEntry, PemEntriesReversed) of
        {ok, _} ->
            {Subject, Expiration} =
                get_chain_info(PemEntriesReversed),

            %% both chains Cert -> I1 -> I2 and Cert -> I1 -> I2 -> Root
            %% are valid and will pass the validation
            [NodeCert | CAChain] =
                lists:reverse(
                  case PemEntriesReversed of
                      [CAPemEntry | _] ->
                          PemEntriesReversed;
                      _ ->
                          [CAPemEntry | PemEntriesReversed]
                  end),
            NodeCertPemEncoded = public_key:pem_encode([NodeCert]),
            case validate_pkey(PKey) of
                ok ->
                    Props = [{subject, Subject},
                             {expires, Expiration},
                             {verified_with, erlang:md5(ClusterCA)},
                             {pem, NodeCertPemEncoded}],
                    case ns_ssl_services_setup:set_node_certificate_chain(
                           Props,
                           public_key:pem_encode(CAChain),
                           NodeCertPemEncoded, PKey) of
                        ok ->
                            {ok, Props};
                        Err ->
                            Err
                    end;
                {error, invalid_pkey, BadType} ->
                    {error, {invalid_pkey, BadType}}
            end;
        {error, _} = Error ->
            Error
    end.

apply_certificate_chain_from_inbox() ->
    case ns_config:search(cert_and_pkey) of
        {value, {ClusterCAProps, _, _}} ->
            ClusterCA = proplists:get_value(pem, ClusterCAProps),
            apply_certificate_chain_from_inbox(ClusterCA);
        _ ->
            {error, no_cluster_ca}
    end.

apply_certificate_chain_from_inbox(ClusterCA) ->
    case file:read_file(inbox_chain_path()) of
        {ok, ChainPEM} ->
            case file:read_file(inbox_pkey_path()) of
                {ok, PKeyPEM} ->
                    set_node_certificate_chain(ClusterCA, ChainPEM, PKeyPEM);
                {error, Reason} ->
                    {error, {read_pkey, inbox_pkey_path(), Reason}}
            end;
        {error, Reason} ->
            {error, {read_chain, inbox_chain_path(), Reason}}
    end.

get_warnings(CAProps) ->
    ClusterCA = proplists:get_value(pem, CAProps),
    false = ClusterCA =:= undefined,

    VerifiedWith = erlang:md5(ClusterCA),

    Config = ns_config:get(),
    Nodes = ns_node_disco:nodes_wanted(Config),

    lists:foldl(
      fun (Node, Acc) ->
              case ns_config:search(Config, {node, Node, cert}) of
                  {value, Props} ->
                      case proplists:get_value(verified_with, Props) of
                          VerifiedWith ->
                              Now = calendar:datetime_to_gregorian_seconds(calendar:universal_time()),
                              WarningDays = ns_config:read_key_fast({cert, expiration_warning_days}, 7),
                              WarningThreshold = Now + WarningDays * 24 * 60 * 60,

                              case proplists:get_value(expires, Props) of
                                  A when is_integer(A) andalso A =< Now ->
                                      [{Node, expired} | Acc];
                                  A when  is_integer(A) andalso A =< WarningThreshold ->
                                      [{Node, {expires_soon, A}} | Acc];
                                  A when is_integer(A) ->
                                      Acc
                              end;
                          _ ->
                              [{Node, mismatch} | Acc]
                      end;
                  false ->
                      [{Node, mismatch} | Acc]
              end
      end, [], Nodes).

get_node_cert_info(Node) ->
    Props = ns_config:read_key_fast({node, Node, cert}, []),
    proplists:delete(verified_with, Props).
