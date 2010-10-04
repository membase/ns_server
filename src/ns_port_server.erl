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
-module(ns_port_server).

-define(ABNORMAL, 0).

-behavior(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-define(NUM_MESSAGES, 3). % Number of the most recent messages to log on crash

-define(UNEXPECTED, 1).

-include_lib("eunit/include/eunit.hrl").

%% Server state
-record(state, {port, name, messages}).


%% API

start_link(Name, Cmd, Args, Opts) ->
    gen_server:start_link(?MODULE,
                          {Name, Cmd, Args, Opts}, []).

init({Name, _Cmd, _Args, _Opts} = Params) ->
    process_flag(trap_exit, true), % Make sure terminate gets called
    Port = open_port(Params),
    {ok, #state{port = Port, name = Name,
                messages = ringbuffer:new(?NUM_MESSAGES)}}.

handle_info({_Port, {data, {_, Msg}}}, State) ->
    State1 = log_messages([Msg], State),
    {noreply, State1};
handle_info({_Port, {exit_status, 0}}, State) ->
    {stop, normal, State};
handle_info({_Port, {exit_status, Status}}, State) ->
    ns_log:log(?MODULE, ?ABNORMAL,
               "Port server ~p on node ~p exited with status ~p. Restarting. "
               "Messages: ~s",
               [State#state.name, node(), Status,
                string:join(ringbuffer:to_list(State#state.messages), "\n")]),
    {stop, {abnormal, Status}, State}.

handle_call(unhandled, unhandled, unhandled) ->
    unhandled.

handle_cast(unhandled, unhandled) ->
    unhandled.

terminate(Reason, #state{name=Name, port=Port}) ->
    Result = (catch port_close(Port)),
    ?log_info("Result of closing port for ~p (exit reason ~p): ~p",
              [Name, Reason, Result]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions

format_lines(Name, Lines) ->
    Prefix = io_lib:format("~p~p: ", [Name, self()]),
    [[Prefix, Line, $\n] || Line <- Lines].

log_messages(L, State) ->
    State1 = State#state{messages=ringbuffer:add(hd(L), State#state.messages)},
    receive
        {_Port, {data, {_, Msg}}} ->
            log_messages([Msg|L], State1)
    after 0 ->
            %% split_log will reverse the lines
            split_log(format_lines(State#state.name, L)),
            State1
    end.

open_port({_Name, Cmd, Args, OptsIn}) ->
    %% Incoming options override existing ones (specified in proplists docs)
    Opts0 = OptsIn ++ [{args, Args}, exit_status, {line, 8192},
                       stderr_to_stdout],
    WriteDataArg = proplists:get_value(write_data, Opts0),
    Opts = lists:keydelete(write_data, 1, Opts0),
    Port = open_port({spawn_executable, Cmd}, Opts),
    case WriteDataArg of
        undefined ->
            ok;
        Data ->
            Port ! {self(), {command, Data}}
    end,
    Port.

%% @doc Split the log into <64k chunks. The lines are fed in backwards.
split_log(L) ->
    split_log(L, [], 0).

split_log([H|T] = L, M, N) ->
    NewLength = N + lists:flatlength(H),
    if NewLength > 65000 ->
            error_logger:info_msg(lists:flatten(M)),
            split_log(L);
       true ->
            split_log(T, [H|M], NewLength)
    end;
split_log([], M, _) ->
    error_logger:info_msg(lists:flatten(M)).
