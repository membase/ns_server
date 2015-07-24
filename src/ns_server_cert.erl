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

-export([cluster_cert_and_pkey_pem/0,
         generate_cert_and_pkey/0,
         do_generate_cert_and_pkey/2,
         validate_cert/1,
         generate_and_set_cert_and_pkey/0]).

cluster_cert_and_pkey_pem() ->
    case ns_config:search(cert_and_pkey) of
        {value, Pair} ->
            Pair;
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
