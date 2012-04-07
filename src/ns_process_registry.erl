%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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
-module(ns_process_registry).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/1, lookup_pid/2, register_pid/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          name :: atom(),
          pids2ids
         }).


lookup_pid(Name, Id) ->
    try ets:lookup(Name, Id) of
        [{_, Pid}] ->
            Pid;
        [] ->
            missing
    catch error:badarg ->
            missing
    end.

register_pid(Name, Id, Pid) ->
    case lookup_pid(Name, ?MODULE) of
        Registry when is_pid(Registry) ->
            gen_server:call(Registry, {register, Id, Pid})
    end.

start_link(Name) ->
    gen_server:start_link(?MODULE, [Name], []).

init([Name]) ->
    ets:new(Name, [public, named_table]),
    PidsToIds = ets:new(none, [private, set]),
    ets:insert(Name, {?MODULE, self()}),
    erlang:process_flag(trap_exit, true),
    {ok, #state{name = Name,
                pids2ids = PidsToIds}}.


consume_death_of(Pid, State) ->
    [Parent | _] = get('ancestors'),
    receive
        {'EXIT', Parent, Reason} = ExitMsg ->
            ?log_debug("Got exit signal from parent: ~p", [ExitMsg]),
            exit(Reason);
        {'EXIT', Pid, _Reason} = PidExitMsg ->
            {noreply, NewState} = handle_info(PidExitMsg, State),
            NewState
    end.

handle_call({register, Id, Pid} = Call, From, #state{name = Name,
                                                     pids2ids = PidsToIds} = State) ->
    case ets:lookup(Name, Id) of
        [] ->
            ets:insert(Name, {Id, Pid}),
            erlang:link(Pid),
            ets:insert(PidsToIds, {Pid, Id}),
            {reply, ok, State};
        [{_, OtherPid}] ->
            case erlang:is_process_alive(OtherPid) of
                true ->
                    {reply, busy, State};
                false ->
                    NewState = consume_death_of(OtherPid, State),
                    handle_call(Call, From, NewState)
            end
    end.


handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason} = ExitMsg, #state{name = Name,
                                                     pids2ids = PidsToIds} = State) ->
    ?log_debug("Got exit msg: ~p", [ExitMsg]),
    case ets:lookup(PidsToIds, Pid) of
        [] ->
            ?log_error("That exit is from unknown process. Crashing...~n~p", [ExitMsg]),
            exit({bad_exit, ExitMsg});
        [{_, Id}] ->
            erlang:unlink(Pid),
            ets:delete(Name, Id),
            ets:delete(PidsToIds, Pid)
    end,
    {noreply, State}.

terminate(_Reason, #state{name = Name}) ->
    [begin
         erlang:exit(Pid, shutdown),
         misc:wait_for_process(Pid, infinity)
     end || {_, Pid} <- ets:tab2list(Name)],
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
