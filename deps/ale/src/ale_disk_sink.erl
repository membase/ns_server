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

-module(ale_disk_sink).

-behaviour(gen_server).

%% API
-export([start_link/2, start_link/3, sink_type/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("ale.hrl").

-record(state, {
          path :: string(),
          file :: file:io_device(),
          buffer :: binary(),
          buffer_size :: integer(),
          flush_timer :: undefined | reference(),

          batch_size :: pos_integer(),
          batch_timeout :: pos_integer()
         }).

start_link(Name, Path) ->
    start_link(Name, Path, []).

start_link(Name, Path, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [Path, Opts], []).

sink_type() ->
    preformatted.

init([Path, Opts]) ->
    process_flag(trap_exit, true),
    File = open_log(Path),

    BatchSize = proplists:get_value(batch_size, Opts, 524288),
    BatchTimeout = proplists:get_value(batch_timeout, Opts, 1000),

    {ok, #state{path = Path,
                file = File,
                buffer = <<>>,
                buffer_size = 0,
                batch_size = BatchSize,
                batch_timeout = BatchTimeout}}.

handle_call({log, Msg}, _From, State) ->
    {reply, ok, log_msg(Msg, State)};
handle_call(sync, _From, State) ->
    {reply, ok, sync(State)};
handle_call(Request, _From, State) ->
    {stop, {unexpected_call, Request}, State}.

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info(flush_buffer, State) ->
    {noreply, flush_buffer(State)};
handle_info(Info, State) ->
    {stop, {unexpected_info, Info}, State}.

terminate(_Reason, State) ->
    flush_buffer(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions
open_log(Path) ->
    {ok, F} = file:open(Path, [raw, append, binary]),
    F.

log_msg(Msg, #state{buffer = Buffer,
                    buffer_size = BufferSize,
                    batch_size = BatchSize} = State) ->
    NewBuffer = <<Buffer/binary, Msg/binary>>,
    NewBufferSize = BufferSize + byte_size(Msg),

    NewState = State#state{buffer = NewBuffer,
                           buffer_size = NewBufferSize},

    case NewBufferSize >= BatchSize of
        true ->
            flush_buffer(NewState);
        false ->
            maybe_arm_flush_timer(NewState)
    end.

flush_buffer(#state{file = File,
                    buffer = Buffer,
                    buffer_size = BufferSize} = State) ->
    case BufferSize =:= 0 of
        true ->
            State;
        false ->
            ok = file:write(File, Buffer),
            NewState = State#state{buffer = <<>>,
                                   buffer_size = 0},
            cancel_flush_timer(NewState)
    end.

maybe_arm_flush_timer(#state{flush_timer = undefined,
                             batch_timeout = Timeout} = State) ->
    TRef = erlang:send_after(Timeout, self(), flush_buffer),
    State#state{flush_timer = TRef};
maybe_arm_flush_timer(State) ->
    State.

cancel_flush_timer(#state{flush_timer = TRef} = State) when TRef =/= undefined ->
    erlang:cancel_timer(TRef),
    receive
        flush_buffer -> ok
    after
        0 -> ok
    end,
    State#state{flush_timer = undefined};
cancel_flush_timer(State) ->
    State.

sync(State) ->
    NewState = flush_buffer(State),
    file:datasync(NewState#state.file),
    NewState.
