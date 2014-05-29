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

-include_lib("kernel/include/file.hrl").
-include("ale.hrl").

-record(state, {
          path :: string(),
          file :: undefined | file:io_device(),
          file_size :: integer(),
          buffer :: binary(),
          buffer_size :: integer(),
          flush_timer :: undefined | reference(),

          batch_size :: pos_integer(),
          batch_timeout :: pos_integer(),
          rotation_size :: non_neg_integer(),
          rotation_num_files :: pos_integer(),
          rotation_compress :: boolean()
         }).

start_link(Name, Path) ->
    start_link(Name, Path, []).

start_link(Name, Path, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, [Path, Opts], []).

sink_type() ->
    preformatted.

init([Path, Opts]) ->
    process_flag(trap_exit, true),

    BatchSize = proplists:get_value(batch_size, Opts, 524288),
    BatchTimeout = proplists:get_value(batch_timeout, Opts, 1000),

    RotationConf = proplists:get_value(rotation, Opts, []),
    RotSize = proplists:get_value(size, RotationConf, 10485760),
    RotNumFiles = proplists:get_value(num_files, RotationConf, 20),
    RotCompress = proplists:get_value(compress, RotationConf, true),

    State = #state{path = Path,
                   buffer = <<>>,
                   buffer_size = 0,
                   batch_size = BatchSize,
                   batch_timeout = BatchTimeout,
                   rotation_size = RotSize,
                   rotation_num_files = RotNumFiles,
                   rotation_compress = RotCompress},

    {ok, open_log_file(State)}.

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

flush_buffer(State) ->
    NewState = do_flush_buffer(State),
    maybe_rotate_files(NewState).

do_flush_buffer(#state{file = File,
                       file_size = FileSize,
                       buffer = Buffer,
                       buffer_size = BufferSize} = State) ->
    case BufferSize =:= 0 of
        true ->
            State;
        false ->
            ok = file:write(File, Buffer),
            NewState = State#state{file_size = FileSize + BufferSize,
                                   buffer = <<>>,
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

rotate_files(#state{path = Path,
                    rotation_num_files = NumFiles,
                    rotation_compress = Compress}) ->
    Suffix = case Compress of
                 true ->
                     ".gz";
                 false ->
                     ""
             end,

    rotate_files_loop(Path, Suffix, NumFiles - 1).

rotate_files_loop(Path, _Suffix, 0) ->
    case file:delete(Path) of
        ok ->
            ok;
        Error ->
            Error
    end;
rotate_files_loop(Path, _Suffix, 1) ->
    To = Path ++ ".1",
    case do_rotate_file(Path, To) of
        ok ->
            ok;
        Error ->
            Error
    end;
rotate_files_loop(Path, Suffix, N) ->
    From = Path ++ "." ++ integer_to_list(N - 1) ++ Suffix,
    To = Path ++ "." ++ integer_to_list(N) ++ Suffix,

    case do_rotate_file(From, To) of
        ok ->
            rotate_files_loop(Path, Suffix, N - 1);
        Error ->
            Error
    end.

do_rotate_file(From, To) ->
    case file:read_file_info(From) of
        {error, enoent} ->
            ok;
        {error, _} = Error ->
            Error;
        {ok, _} ->
            case file:rename(From, To) of
                ok ->
                    ok;
                Error ->
                    Error
            end
    end.

maybe_rotate_files(#state{file_size = FileSize,
                          rotation_size = RotSize} = State)
  when RotSize =/= 0, FileSize >= RotSize ->
    ok = rotate_files(State),
    ok = maybe_compress_post_rotate(State),
    open_log_file(State);
maybe_rotate_files(State) ->
    State.

open_log_file(#state{path = Path,
                     file = OldFile} = State) ->
    case OldFile of
        undefined ->
            ok;
        _ ->
            file:close(OldFile)
    end,

    {ok, File, #file_info{size = Size}} = open_file(Path),
    State#state{file = File,
                file_size = Size}.

open_file(Path) ->
    case file:read_file_info(Path) of
        {ok, Info} ->
            do_open_file(Path, Info);
        {error, enoent} ->
            case file:open(Path, [raw, append, binary]) of
                {ok, File} ->
                    file:close(File),
                    open_file(Path);
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

do_open_file(Path, #file_info{inode = Inode}) ->
    case file:open(Path, [raw, append, binary]) of
        {ok, File} ->
            case file:read_file_info(Path) of
                {ok, #file_info{inode = Inode} = Info} -> % Inode is bound
                    {ok, File, Info};
                {ok, OtherInfo} ->
                    file:close(File),
                    do_open_file(Path, OtherInfo);
                Error ->
                    file:close(File),
                    Error
            end;
        Error ->
            Error
    end.

maybe_compress_post_rotate(#state{path = Path,
                                  rotation_num_files = NumFiles,
                                  rotation_compress = true})
  when NumFiles > 1 ->
    UncompressedPath = Path ++ ".1",
    CompressedPath = Path ++ ".1.gz",
    compress_file(UncompressedPath, CompressedPath);
maybe_compress_post_rotate(_) ->
    ok.

compress_file(FromPath, ToPath) ->
    {ok, From} = file:open(FromPath, [raw, binary, read]),

    try
        {ok, To} = file:open(ToPath, [raw, binary, write]),
        Z = zlib:open(),

        try
            ok = zlib:deflateInit(Z, default, deflated, 15 + 16, 8, default),
            compress_file_loop(From, To, Z),
            ok = zlib:deflateEnd(Z),
            ok = file:delete(FromPath)
        after
            file:close(To),
            zlib:close(Z)
        end
    after
        file:close(From)
    end.

compress_file_loop(From, To, Z) ->
    {Compressed, Continue} =
        case file:read(From, 1024 * 1024) of
            eof ->
                {zlib:deflate(Z, <<>>, finish), false};
            {ok, Data} ->
                {zlib:deflate(Z, Data), true}
        end,

    case iolist_to_binary(Compressed) of
        <<>> ->
            ok;
        CompressedBinary ->
            ok = file:write(To, CompressedBinary)
    end,

    case Continue of
        true ->
            compress_file_loop(From, To, Z);
        false ->
            ok
    end.
