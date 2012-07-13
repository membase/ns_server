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
%% This module exists to slow down supervisors to prevent fast spins
%% on crashes.
%%
-module(supervisor_cushion).

-behaviour(gen_server).
-behavior(ns_log_categorizing).

-include("ns_common.hrl").

-define(FAST_CRASH, 1).

%% API
-export([start_link/5]).
-export([ns_log_cat/1, ns_log_code_string/1, child_pid/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {name, delay, started, child_pid}).

start_link(Name, Delay, M, F, A) ->
    gen_server:start_link(?MODULE, [Name, Delay, M, F, A], []).

init([Name, Delay, M, F, A]) ->
    process_flag(trap_exit, true),
    ?log_debug("starting ~p with delay of ~p", [M, Delay]),
    case apply(M, F, A) of
        {ok, Pid} ->
            {ok, #state{name=Name, delay=Delay, started=now(), child_pid=Pid}};
        X ->
            {ok, die_slowly(X, #state{name=Name, delay=Delay, started=now()})}
    end.

handle_call(child_pid, _From, State) ->
    {reply, State#state.child_pid, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    ?log_info("Cushion managed supervisor for ~p failed:  ~p",
              [State#state.name, Reason]),
    State1 = die_slowly(Reason, State),
    {noreply, State1};
handle_info({die, Reason}, State) ->
    {stop, Reason, State};
handle_info(Info, State) ->
    ?log_warning("Cushion got unexpected info supervising ~p: ~p",
                 [State#state.name, Info]),
    {noreply, State}.

die_slowly(Reason, State) ->
    %% How long (in microseconds) has this service been running?
    Lifetime = timer:now_diff(now(), State#state.started),
    %% now_diff returns microseconds, so let's do the same.
    MinDelay = State#state.delay * 1000,
    %% If the restart was too soon, slow down a bit.
    case Lifetime < MinDelay of
        true ->
            ?user_log(?FAST_CRASH,
                      "Service ~p exited on node ~p in ~.2fs~n",
                      [State#state.name, node(), Lifetime / 1000000]),
            timer:send_after(State#state.delay, {die, Reason});
        _ -> self() ! {die, Reason}
    end,
    State#state{child_pid=undefined}.

terminate(_Reason, #state{child_pid = undefined}) ->
    ok;
terminate(Reason, State) ->
    Pid = State#state.child_pid,
    erlang:exit(Pid, Reason),
    receive
        {'EXIT', Pid, _Reason2} ->
            ok
    end.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ns_log_cat(?FAST_CRASH) -> warn.

ns_log_code_string(?FAST_CRASH) -> "port exited too soon after restart".

%% API
child_pid(Pid) ->
    gen_server:call(Pid, child_pid).
