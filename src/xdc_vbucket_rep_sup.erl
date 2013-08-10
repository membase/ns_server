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
-behaviour(supervisor2).
-export([start_link/1, shutdown/1, start_vbucket_rep/7, stop_vbucket_rep/2]).
-export([vbucket_reps/1]).

-export([init/1]).

-include("xdc_replicator.hrl").

start_link(ChildSpecs) ->
    {ok, Sup} = supervisor2:start_link(?MODULE, ChildSpecs),
    ?xdcr_debug("xdc vbucket replicator supervisor started: ~p", [Sup]),
    {ok, Sup}.

start_vbucket_rep(Sup, Rep, Vb, InitThrottle, WorkThrottle, Parent, RepMode) ->
    #rep{options = Options} = Rep,
    RestartWaitTime = proplists:get_value(failure_restart_interval, Options),
    ?xdcr_debug("start xdc vbucket replicator (vb: ~p, restart wait time: ~p, "
                "parent pid: ~p, mode: ~p)",
                [Vb, RestartWaitTime, Parent, RepMode]),

    Spec = {Vb,
            {xdc_vbucket_rep, start_link, [Rep, Vb, InitThrottle, WorkThrottle, Parent, RepMode]},
            {permanent, RestartWaitTime},
            100,
            worker,
            [xdc_vbucket_rep]
           },
    supervisor2:start_child(Sup, Spec).

% return all the child vbucket replicators being supervised
vbucket_reps(Sup) ->
    [element(1, Spec) || Spec <- supervisor2:which_children(Sup)].

stop_vbucket_rep(Sup, Vb) ->
    supervisor2:terminate_child(Sup, Vb),
    supervisor2:delete_child(Sup, Vb).

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
    % we fast retry 2 times in one second, after that we use the restart
    % setting environment var XDCR_FAILURE_RESTART_INTERVAL that is added to
    % the child spec
    {ok, {{one_for_one, 2, 1}, ChildSpecs}}.

%%=============================================================================
%% internal functions
%%=============================================================================
