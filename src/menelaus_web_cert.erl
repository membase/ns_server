%% @author Couchbase <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
%% @doc REST api's for handling ssl certificates

-module(menelaus_web_cert).

-include("ns_common.hrl").

-export([handle_cluster_certificate/1,
         handle_regenerate_certificate/1]).

handle_cluster_certificate(Req) ->
    menelaus_web:assert_is_enterprise(),

    {Cert, _} = ns_server_cert:cluster_cert_and_pkey_pem(),
    menelaus_util:reply_ok(Req, "text/plain", Cert).

handle_regenerate_certificate(Req) ->
    menelaus_web:assert_is_enterprise(),

    ns_server_cert:generate_and_set_cert_and_pkey(),
    ns_ssl_services_setup:sync_local_cert_and_pkey_change(),
    ?log_info("Completed certificate regeneration"),
    ns_audit:regenerate_certificate(Req),
    handle_cluster_certificate(Req).
