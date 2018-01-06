%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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

%% @doc implementation of alternate_addresses functions that serve
%% alternate_addresses information stored in ns_config.

-module(alternate_addresses).

-export([map_port/2,
         service_ports/1,
         filter_rename_ports/2,
         get_external/0,
         get_external/2]).

-include("ns_common.hrl").

-record(port, {config, rest, service}).
-define(define_port(ConfName, RestName, Service),
        #port{config  = ConfName,
              rest    = <<??RestName>>,
              service = Service}).
all_ports() ->
    [%% rest service ports
     ?define_port(rest_port, mgmt, rest),
     ?define_port(ssl_rest_port, mgmtSSL, rest),
     %% kv service ports
     ?define_port(memcached_port, kv, kv),
     ?define_port(memcached_ssl_port, kvSSL, kv),
     ?define_port(capi_port, capi, kv),
     ?define_port(ssl_capi_port, capiSSL, kv),
     ?define_port(projector_port, projector, kv),
     ?define_port(moxi_port, moxi, kv),
     %% query service ports
     ?define_port(query_port, n1ql, n1ql),
     ?define_port(ssl_query_port, n1qlSSL, n1ql),
     %% index service ports
     ?define_port(indexer_admin_port, indexAdmin, index),
     ?define_port(indexer_scan_port, indexScan, index),
     ?define_port(indexer_http_port, indexHttp, index),
     ?define_port(indexer_https_port, indexHttps, index),
     ?define_port(indexer_stinit_port, indexStreamInit, index),
     ?define_port(indexer_stcatchup_port, indexStreamCatchup, index),
     ?define_port(indexer_stmaint_port, indexStreamMaint, index),
     %% fts service ports
     ?define_port(fts_http_port, fts, fts),
     ?define_port(fts_ssl_port, ftsSSL, fts),
     %% eventing service ports
     ?define_port(eventing_http_port, eventingAdminPort, eventing),
     ?define_port(eventing_https_port, eventingSSL, eventing),
     %% cbas service ports
     ?define_port(cbas_http_port, cbas, cbas),
     ?define_port(cbas_admin_port, cbasAdmin, cbas),
     ?define_port(cbas_cc_http_port, cbasCc, cbas),
     ?define_port(cbas_ssl_port, cbasSSL, cbas),
     %% miscellaneous cbas ports
     ?define_port(cbas_cluster_port, cbasCluster, misc),
     ?define_port(cbas_cc_cluster_port, cbasCcCluster, misc),
     ?define_port(cbas_cc_client_port, cbasCcClient, misc),
     ?define_port(cbas_hyracks_console_port, cbasHyracksConsole, misc),
     ?define_port(cbas_data_port, cbasData, misc),
     ?define_port(cbas_result_port, cbasResult, misc),
     ?define_port(cbas_messaging_port, cbasMessaging, misc),
     ?define_port(cbas_debug_port, cbasDebug, misc),
     ?define_port(cbas_auth_port, cbasAuth, misc),
     ?define_port(cbas_replication_port, cbasReplication, misc),
     %% miscellaneous ports
     ?define_port(ssl_proxy_downstream_port, sslProxy, misc),
     ?define_port(ssl_proxy_upstream_port, sslProxyUpstream, misc)].

service_ports(Service) ->
    [P#port.config || P <- all_ports(), P#port.service =:= Service].

map_port(from_rest, Port) ->
    map_port(Port, #port.rest, #port.config);
map_port(from_config, Port) ->
    map_port(Port, #port.config, #port.rest).

map_port(Port, FromField, ToField) ->
    case lists:keyfind(Port, FromField, all_ports()) of
        false -> throw({error, [<<"No such port">>]});
        Tuple -> element(ToField, Tuple)
    end.

get_external() ->
    get_external(node(), ns_config:latest()).
get_external(Node, Config) ->
    External = ns_config:search_node_prop(Node, Config,
                                          alternate_addresses, external,
                                          []),
    Hostname = proplists:get_value(hostname, External),
    Ports    = proplists:get_value(ports, External, []),
    {Hostname, Ports}.

filter_rename_ports([], _WantedPorts) -> [];
filter_rename_ports(Ports, WantedPorts) ->
    lists:filtermap(
      fun (ConfigName) ->
              case lists:keyfind(ConfigName, 1, Ports) of
                  false ->
                      false;
                  {_ConfigName, Value} ->
                      RestName = map_port(from_config, ConfigName),
                      {true, {RestName, Value}}
              end
      end, WantedPorts).
