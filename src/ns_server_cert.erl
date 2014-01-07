-module(ns_server_cert).

-include("ns_common.hrl").

-export([cluster_cert_and_pkey_pem/0,
         generate_cert_and_pkey/0,
         validate_cert/1,
         generate_and_set_cert_and_pkey/0]).

cluster_cert_and_pkey_pem() ->
    RV = ns_config:run_txn(
           fun (Config, SetFn) ->
                   case ns_config:search(Config, cert_and_pkey) of
                       {value, Pair} ->
                           {abort, Pair};
                       false ->
                           CP = generate_cert_and_pkey(),
                           {commit, SetFn(cert_and_pkey, CP, Config)}
                   end
           end),
    case RV of
        {abort, Pair} ->
            Pair;
        _ ->
            {value, Pair} = ns_config:search(cert_and_pkey),
            Pair
    end.

generate_and_set_cert_and_pkey() ->
    Pair = generate_cert_and_pkey(),
    ns_config:set(cert_and_pkey, Pair).

generate_cert_and_pkey() ->
    StartTS = os:timestamp(),
    RV = do_generate_cert_and_pkey(),
    EndTS = os:timestamp(),

    Diff = timer:now_diff(EndTS, StartTS),
    ?log_debug("Generated certificate and private key in ~p us", [Diff]),

    RV.

do_generate_cert_and_pkey() ->
    {Status, Output} = misc:run_external_tool(path_config:component_path(bin, "generate_cert"), []),
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
