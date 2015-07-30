%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
-module(saslauthd_auth).

-include("ns_common.hrl").

-export([build_settings/0,
         set_settings/1,
         check/2
        ]).

verify_creds(Username, Password) ->
    case json_rpc_connection:perform_call('saslauthd-saslauthd-port', "SASLDAuth.Check",
                                          {[{user, list_to_binary(Username)},
                                            {password, list_to_binary(Password)}]}) of
        {ok, Resp} ->
            Resp =:= true;
        {error, ErrorMsg} = Error ->
            ?log_error("Revrpc to saslauthd returned error: ~p", [ErrorMsg]),
            Error
    end.

build_settings() ->
    case ns_config:search(saslauthd_auth_settings) of
        {value, Settings} ->
            Settings;
        false ->
            [{enabled, false},
             {admins, []},
             {roAdmins, []}]
    end.

set_settings(Settings) ->
    ns_config:set(saslauthd_auth_settings, Settings).

check(User, Password) ->
    LDAPCfg = build_settings(),
    Enabled = ({enabled, true} =:= lists:keyfind(enabled, 1, LDAPCfg)),
    case Enabled of
        false ->
            false;
        true ->
            case verify_creds(User, Password) of
                true ->
                    {_, Admins} = lists:keyfind(admins, 1, LDAPCfg),
                    {_, RoAdmins} = lists:keyfind(roAdmins, 1, LDAPCfg),
                    UserB = list_to_binary(User),
                    IsAdmin = is_list(Admins) andalso lists:member(UserB, Admins),
                    IsRoAdmin = is_list(RoAdmins) andalso lists:member(UserB, RoAdmins),
                    if
                        IsAdmin ->
                            admin;
                        IsRoAdmin ->
                            ro_admin;
                        Admins =:= asterisk ->
                            admin;
                        RoAdmins =:= asterisk ->
                            ro_admin;
                        true ->
                            false
                    end;
                Other ->
                    Other
            end
    end.
