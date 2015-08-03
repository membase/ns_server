%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
%%
-module(ns_error_messages).

-export([decode_json_response_error/3,
         connection_error_message/3,
         engage_cluster_json_error/1,
         bad_memory_size_error/3,
         incompatible_cluster_version_error/3,
         too_old_version_error/2,
         verify_otp_connectivity_port_error/2,
         verify_otp_connectivity_connection_error/4,
         unsupported_services_error/2,
         topology_limitation_error/0]).

-spec connection_error_message(term(), string(), string() | integer()) -> binary() | undefined.
connection_error_message({Error, _}, Host, Port) ->
    connection_error_message(Error, Host, Port);
connection_error_message(nxdomain, Host, _Port) ->
    list_to_binary(io_lib:format("Failed to resolve address for ~p.  "
                                 "The hostname may be incorrect or not resolvable.", [Host]));
connection_error_message(econnrefused, Host, Port) ->
    list_to_binary(io_lib:format("Could not connect to ~p on port ~p.  "
                                 "This could be due to an incorrect host/port combination or a "
                                 "firewall in place between the servers.", [Host, Port]));
connection_error_message(timeout, Host, Port) ->
    list_to_binary(io_lib:format("Timeout connecting to ~p on port ~p.  "
                                 "This could be due to an incorrect host/port combination or a "
                                 "firewall in place between the servers.", [Host, Port]));
connection_error_message("bad certificate", Host, Port) ->
    list_to_binary(io_lib:format("Got certificate mismatch while trying to send https request to ~s:~w",
                                 [Host, Port]));
connection_error_message(_, _, _) -> undefined.

-spec decode_json_response_error({ok, term()} | {error, term()},
                                 atom(),
                                 {string(), string() | integer(), string(), string(), iolist()}) ->
                                        %% English error message and nested error
                                        {error, rest_error, binary(), {error, term()} | {bad_status, integer(), string()}}.
decode_json_response_error({ok, {{200 = _StatusCode, _} = _StatusLine,
                               _Headers, _Body} = _Result},
                         _Method, _Request) ->
    %% 200 is not error
    erlang:error(bug);

decode_json_response_error({ok, {{401 = StatusCode, _}, _, Body}},
                         Method,
                         {Host, Port, Path, _MimeType, _Payload}) ->
    TrimmedBody = string:substr(erlang:binary_to_list(Body), 1, 48),
    RealPort = if is_integer(Port) -> integer_to_list(Port);
                  true -> Port
               end,
    M = list_to_binary(io_lib:format("Authentication failed. Verify username and password. "
                                     "Got HTTP status ~p from REST call ~p to http://~s:~s~s. Body was: ~p",
                                     [StatusCode, Method, Host, RealPort, Path, TrimmedBody])),
    {error, rest_error, M, {bad_status, StatusCode, list_to_binary(TrimmedBody)}};

decode_json_response_error({ok, {{StatusCode, _}, _, Body}},
                         Method,
                         {Host, Port, Path, _MimeType, _Payload}) ->
    TrimmedBody = string:substr(erlang:binary_to_list(Body), 1, 48),
    RealPort = if is_integer(Port) -> integer_to_list(Port);
                  true -> Port
               end,
    M = list_to_binary(io_lib:format("Got HTTP status ~p from REST call ~p to http://~s:~s~s. Body was: ~p",
                                     [StatusCode, Method, Host, RealPort, Path, TrimmedBody])),
    {error, rest_error, M, {bad_status, StatusCode, list_to_binary(TrimmedBody)}};

decode_json_response_error({error, Reason} = E, Method, {Host, Port, Path, _MimeType, _Payload}) ->
    M = case connection_error_message(Reason, Host, Port) of
            undefined ->
                RealPort = if is_integer(Port) -> integer_to_list(Port);
                              true -> Port
                           end,
                list_to_binary(io_lib:format("Error ~p happened during REST call ~p to http://~s:~s~s.",
                                             [Reason, Method, Host, RealPort, Path]));
            X -> X
        end,
    {error, rest_error, M, E}.

engage_cluster_json_error(undefined) ->
    <<"Cluster join prepare call returned invalid json.">>;
engage_cluster_json_error({unexpected_json, _Where, Field} = _Exc) ->
    list_to_binary(io_lib:format("Cluster join prepare call returned invalid json. "
                                 "Invalid field is ~s.", [Field])).

bad_memory_size_error(Services0, TotalQuota, MaxQuota) ->
    Services1 = lists:sort(Services0),
    Services = string:join([atom_to_list(S) || S <- Services1], ", "),

    Msg = io_lib:format("This server does not have sufficient memory to "
                        "support requested memory quota. "
                        "Total quota is ~bMB (services: ~s), "
                        "maximum allowed quota for the node is ~bMB.",
                        [TotalQuota, Services, MaxQuota]),
    iolist_to_binary(Msg).

incompatible_cluster_version_error(MyVersion, OtherVersion, OtherNode) ->
    case MyVersion > 1 of
        true ->
            RequiredVersion = [MyVersion div 16#10000,
                               MyVersion rem 16#10000],
            OtherVersionExpand = case OtherVersion > 1 of
                                     true ->
                                         [OtherVersion div 16#10000,
                                          OtherVersion rem 16#10000];
                                     false ->
                                         [1,8]
                                 end,
            list_to_binary(io_lib:format("This node cannot add another node (~p)"
                                         " because of cluster version compatibility mismatch. Cluster works in ~p mode and node only supports ~p",
                                         [OtherNode, RequiredVersion, OtherVersionExpand]));
        false ->
            list_to_binary(io_lib:format("This node cannot add another node (~p)"
                                         " because of cluster version compatibility mismatch (~p =/= ~p).",
                                         [OtherNode, MyVersion, OtherVersion]))
    end.

too_old_version_error(Node, Version) ->
    MinSupported0 = lists:map(fun integer_to_list/1,
                              cluster_compat_mode:min_supported_compat_version()),
    MinSupported = string:join(MinSupported0, "."),
    Msg = io_lib:format("Joining ~s node ~s is not supported. "
                        "Upgrade node to Couchbase Server "
                        "version ~s or greater and retry.",
                        [Version, Node, MinSupported]),
    iolist_to_binary(Msg).

verify_otp_connectivity_port_error(OtpNode, _Port) ->
    list_to_binary(io_lib:format("Failed to obtain otp port from erlang port mapper for node ~p."
                                 " This can be network name resolution or firewall problem.", [OtpNode])).

verify_otp_connectivity_connection_error(Reason, OtpNode, Host, Port) ->
    Detail = case connection_error_message(Reason, Host, integer_to_list(Port)) of
                 undefined -> [];
                 X -> [" ", X]
             end,
    list_to_binary(io_lib:format("Failed to reach otp port ~p for node ~p.~s"
                                 " This can be firewall problem.", [Port, Detail, OtpNode])).

unsupported_services_error(AvailableServices, RequestedServices) ->
    list_to_binary(io_lib:format("Node doesn't support requested services: ~p. Supported services: ~p",
                                 [RequestedServices, AvailableServices])).

topology_limitation_error() ->
    <<"Community edition supports either data only nodes or nodes with all services enabled.">>.
