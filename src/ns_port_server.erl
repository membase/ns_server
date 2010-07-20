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

-behavior(gen_server).
-behavior(ns_log_categorizing).

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

-define(UNEXPECTED, 1).
-export([ns_log_cat/1, ns_log_code_string/1]).

-include_lib("eunit/include/eunit.hrl").

%% Server state
-record(state, {port, name}).


%% API

start_link(Name, Cmd, Args, Opts) ->
    gen_server:start_link(?MODULE,
                          {Name, Cmd, Args, Opts}, []).

init({Name, _Cmd, _Args, _Opts} = Params) ->
    Port = open_port(Params),
    case is_port(Port) of
        true  -> {ok, #state{port = Port, name = Name}};
        false -> ns_log:log(?MODULE, 0001, "could not start process: ~p",
                            [Params]),
                 {stop, Port}
    end.

handle_info({_Port, {data, Msg}}, State) ->
    timer:sleep(100), % Let messages build up in our queue
    log_messages(State#state.name, [Msg]),
    {noreply, State};
handle_info({_Port, {exit_status, Status}}, State) ->
    error_logger:info_msg("~p exited with status ~p~n",
                          [State#state.name, Status]),
    {stop, normal, State};
handle_info(Something, State) ->
    error_logger:info_msg("Got unexpected message while monitoring ~p: ~p~n",
                          [State#state.name, Something]),
    {stop, {error, {unhandled, Something}}, State}.

handle_call(Something, _From, State) ->
    error_logger:info_msg("Unexpected call: ~p~n", [Something]),
    {reply, {error, {unhandled, Something}}, State}.

handle_cast(Something, State) ->
    error_logger:info_msg("Unexpected cast: ~p~n", [Something]),
    {noreply, State}.

terminate(normal, State) ->
    error_logger:info_msg("port server terminating ~p: ~p~n",
                          [State#state.name, normal]),
    ok;
terminate({port_exited, Reason}, State) ->
    error_logger:info_msg("port server terminating ~p: port exited with reason ~p~n",
                          [State#state.name, Reason]),
    ok;
terminate(Reason, State) ->
    error_logger:info_msg("port server terminating ~p: ~p~n",
                          [State#state.name, Reason]),
    (catch port_close(State#state.port)),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Internal functions

open_port({_Name, Cmd, Args, OptsIn}) ->
    {ok, Pwd} = file:get_cwd(),
    %% Incoming options override existing ones (specified in proplists docs)
    Opts = OptsIn ++ [{args, Args}, exit_status],
    error_logger:info_msg("port server starting: ~p in ~p with ~p / ~p~n",
                          [Cmd, Pwd, Args, Opts]),
    open_port({spawn_executable, Cmd}, Opts).

log_messages(Name, L) ->
    receive
        {_Port, {data, Msg}} ->
            log_messages(Name, [Msg|L])
    after 0 ->
            ?log_info("Message from ~p:~n~s",
                      [Name, lists:append(lists:reverse(L))])
    end.


%% ns_log stuff

ns_log_cat(?UNEXPECTED) -> warn.

ns_log_code_string(?UNEXPECTED) -> "unexpected message monitoring port".
