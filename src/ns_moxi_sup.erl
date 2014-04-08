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
-module(ns_moxi_sup).

-include("ns_common.hrl").

-export([rest_user/0, rest_pass/0]).

%%
%% API
%%

%% used by moxi entry in port_servers config
rest_pass() ->
    ns_config_auth:get_password(special).

%% used by moxi entry in port_servers config
rest_user() ->
    ns_config_auth:get_user(special).
