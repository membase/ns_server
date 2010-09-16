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
    Port = open_port(Params),
    {ok, #state{port = Port, name = Name,
                messages = ringbuffer:new(?NUM_MESSAGES)}}.

handle_info({_Port, {data, Msg}}, State) ->
    State1 = log_messages([Msg], State),
    {noreply, State1};
handle_info({_Port, {exit_status, 0}}, State) ->
    {stop, normal, State};
handle_info({_Port, {exit_status, Status}}, State) ->
    ns_log:log(?MODULE, ?ABNORMAL,
               "Port server ~p on node ~p exited with status ~p. Restarting. "
               "Messages: ~s",
               [State#state.name, nodes(), Status,
                lists:append(ringbuffer:to_list(State#state.messages))]),
    {stop, {abnormal, Status}, State}.

handle_call(unhandled, unhandled, unhandled) ->
    unhandled.

handle_cast(unhandled, unhandled) ->
    unhandled.

terminate(_Reason, #state{port=Port}) ->
    (catch port_close(Port)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions

open_port({_Name, Cmd, Args, OptsIn}) ->
    %% Incoming options override existing ones (specified in proplists docs)
    Opts0 = OptsIn ++ [{args, Args}, exit_status],
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

log_messages(L, State) ->
    State1 = State#state{messages=ringbuffer:add(hd(L), State#state.messages)},
    receive
        {_Port, {data, Msg}} ->
            log_messages([Msg|L], State1)
    after 0 ->
            split_log(State1#state.name, L, []),
            State1
    end.

split_log(Name, L, M) ->
    case L == [] orelse lists:flatlength(L) + length(hd(L)) > 65000 of
        true ->
            ?log_info("Message from ~p:~n~s",
                      [Name, lists:append(M)]);
        false ->
            split_log(Name, tl(L), [hd(L)|M])
    end.
