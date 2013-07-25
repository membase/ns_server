%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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
%% @doc This module implements logging of verbose system-wide
%% diagnostics for diag_handler:diagnosing_timeouts
-module(timeout_diag_logger).

-behaviour(gen_server).

-include("ns_common.hrl").

%% API
-export([start_link/0, log_diagnostics/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MIN_LOG_INTERVAL, 5000).

-record(state, {last_tstamp}).

%%%===================================================================
%%% API
%%%===================================================================

log_diagnostics(Err) ->
    Pid = erlang:whereis(?MODULE),
    case Pid of
        undefined -> ok;
        _ ->
            try erlang:process_info(Pid, message_queue_len) of
                {_, V} when V < 1 -> gen_server:cast(?MODULE, {diag, Err});
                _ -> nothing
            catch _:_ -> nothing
            end
    end.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok, #state{last_tstamp = misc:time_to_epoch_ms_int(now()) - ?MIN_LOG_INTERVAL}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_, _From, _State) ->
    erlang:error(unsupported).

do_diag(Err, #state{last_tstamp = TStamp} = State) ->
    self() ! busy_marker,
    Now = misc:time_to_epoch_ms_int(now()),
    NewState =
        case Now - TStamp >= ?MIN_LOG_INTERVAL of
            true ->
                Processes = lists:foldl(fun (Pid, Acc) ->
                                                [{Pid, (catch diag_handler:grab_process_info(Pid))} | Acc]
                                        end, [], erlang:processes()),
                ?log_error("Got timeout ~p~nProcesses snapshot is: ~n", [Err]),
                lists:foreach(fun (Item) ->
                                      ?log_error("~n~p", [Item])
                              end, Processes),
                State#state{last_tstamp = misc:time_to_epoch_ms_int(now())};
            _ -> State
        end,
    NewState.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({diag, Err}, State) ->
    {noreply, do_diag(Err, State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

