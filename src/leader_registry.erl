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

%% This module provides a wrapper around global and
%% leader_registry_server. This is needed for providing backward compatibility
%% in mixed clusters. This is achieved by registering both with global and
%% leader_registry_server when cluster compatibility version is not
%% vulcan. Eventually, %% we'll just be able to replace leader_registry with
%% leader_registry_server once backward compatibility is not a concern
%% anymore.
-module(leader_registry).

-include("ns_common.hrl").

%% name service API
-export([register_name/2, unregister_name/1, whereis_name/1, send/2]).

register_name(Name, Pid) ->
    wrap_regisry_api(register_name, [Name, Pid]).

unregister_name(Name) ->
    wrap_regisry_api(unregister_name, [Name]).

whereis_name(Name) ->
    wrap_regisry_api(whereis_name, [Name]).

send(Name, Msg) ->
    case whereis_name(Name) of
        Pid when is_pid(Pid) ->
            Pid ! Msg,
            Pid;
        undefined ->
            exit({badarg, {Name, Msg}})
    end.

%% internal
backends() ->
    case force_use_global() of
        true ->
            [global];
        false ->
            case cluster_compat_mode:is_cluster_vulcan() of
                true ->
                    [leader_registry_server];
                false ->
                    [global, leader_registry_server]
            end
    end.

wrap_regisry_api(Name, Args) ->
    Empty = make_ref(),
    lists:foldl(
      fun (Mod, PrevResult) ->
              Result = erlang:apply(Mod, Name, Args),

              case PrevResult =:= Empty orelse PrevResult =:= Result of
                  true ->
                      ok;
                  false ->
                      ?log_error("Leader registry backend ~p:~p(~p) "
                                 "result '~p' is different "
                                 "from the previous '~p'",
                                 [Mod, Name, Args, Result, PrevResult]),
                      exit({leader_registry_results_dont_match,
                            {Mod, Name, Args},
                            Result,
                            PrevResult})
              end,

              Result
      end, Empty, backends()).

force_use_global() ->
    ns_config:read_key_fast(force_use_global, false).
