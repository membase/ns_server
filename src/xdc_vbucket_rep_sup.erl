% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(xdc_vbucket_rep_sup).
-behaviour(supervisor).
-export([shutdown/1]).

-export([init/1, start_link/1]).

-include("xdc_replicator.hrl").

start_link(ChildSpecs) ->
    {ok, Sup} = supervisor:start_link(?MODULE, ChildSpecs),
    ?xdcr_debug("xdc vbucket replicator supervisor started: ~p", [Sup]),
    {ok, Sup}.

shutdown(Sup) ->
    ?xdcr_debug("shutdown xdc vbucket replicator supervisor ~p",  [Sup]),
    MonRef = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', MonRef, _Type, _Object, _Info} ->
        ok
    end.

%%=============================================================================
%% supervisor callbacks
%%=============================================================================

init(ChildSpecs) ->
    {ok, {{one_for_one, 100, 600}, ChildSpecs}}.

%%=============================================================================
%% internal functions
%%=============================================================================
