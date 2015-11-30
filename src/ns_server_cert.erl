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

-export([cluster_cert_and_pkey_pem/0,
         do_generate_cert_and_pkey/2,
         validate_cert/1,
         generate_and_set_cert_and_pkey/0,
         cluster_ca/0,
         set_cluster_ca/1]).

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

cluster_cert_and_pkey_pem() ->
    case cluster_ca() of
        {_, _} = Pair ->
            Pair;
        {_, Cert, Key} ->
            {Cert, Key}
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
            {error, pkey_not_found, BadType}
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
            Info = {Subject, NotBefore, NotAfter} =
                try
                    get_info(RootCertDer)
                catch T:E ->
                        {error, malformed_cert, {T,E,erlang:get_stacktrace()}}
                end,
            case Info of
                {error, malformed_cert, _} = E1 ->
                    E1;
                _ ->
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
                    ok;
                retry_needed ->
                    erlang:error(exceeded_retries)
            end;
        {error, Error, _} = Err ->
            ?log_error("Certificate authority validation failed with ~p", [Err]),
            {error, Error}
    end.
