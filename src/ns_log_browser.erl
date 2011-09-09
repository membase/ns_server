-module(ns_log_browser).

-export([start/0]).
-export([log_exists/1, log_exists/2]).
-export([stream_logs/1, stream_logs/2, stream_logs/3, stream_logs/4]).

-include("ns_common.hrl").

-spec usage([1..255, ...], list()) -> no_return().
usage(Fmt, Args) ->
    io:format(Fmt, Args),
    usage().

-spec usage() -> no_return().
usage() ->
    io:format("Usage: <progname> -report_dir <dir> [-log <name>]~n"),
    halt(1).

start() ->
    Options = case parse_arguments([{h, 0, undefined, false},
                                    {report_dir, 1, undefined},
                                    {log, 1, undefined, ?DEFAULT_LOG_FILENAME}],
                                   init:get_arguments()) of
                  {ok, O} ->
                      O;
                  {missing_option, K} ->
                      usage("option ~p is required~n", [K]);
                  {parse_error, {wrong_number_of_args, _, N}, K, _} ->
                      usage("option ~p requires ~p arguments~n", [K, N]);
                  Error -> usage("parse error: ~p~n", [Error])
              end,

    case proplists:get_value(h, Options) of
        true -> usage();
        false -> ok
    end,
    Dir = proplists:get_value(report_dir, Options),
    Log = proplists:get_value(log, Options),

    case log_exists(Dir, Log) of
        true ->
            stream_logs(Dir, Log,
                        fun (Data) ->
                                %% originally standard_io was used here
                                %% instead of group_leader(); though this is
                                %% perfectly valid (e.g. this tested in
                                %% otp/lib/kernel/tests/file_SUITE.erl) it makes
                                %% dialyzer unhappy
                                file:write(group_leader(), Data)
                        end);
        false ->
            usage("Requested log file ~p does not exist.~n", [Log])
    end.

%% Option parser
map_args(K, N, undefined, D, A) ->
    map_args(K, N, fun(L) -> L end, D, A);
map_args(K, N, F, D, A) ->
    try map_args(N, F, D, A)
    catch error:Reason ->
            erlang:error({parse_error, Reason, K, A})
    end.

map_args(_N, _F, D, []) -> D;
map_args(0, _F, _D, _A) -> true;
map_args(one_or_more, F, _D, A) ->
    L = lists:append(A),
    case length(L) of
        0 -> erlang:error(one_or_more);
        _ -> F(L)
    end;
map_args(many, F, _D, A) -> F(lists:append(A));
map_args(multiple, F, _D, A) -> F(A);
map_args(N, F, _D, A) when is_function(F, N) ->
    L = lists:append(A),
    case length(L) of
        N -> apply(F, L);
        X -> erlang:error({wrong_number_of_args, X, N})
    end;
map_args(N, F, _D, A) when is_function(F, 1) ->
    L = lists:append(A),
    N = length(L),
    F(L).

parse_arguments(Opts, Args) ->
    try lists:map(fun
                      ({K, N, F, D}) -> {K, map_args(K, N, F, D, proplists:get_all_values(K, Args))};
                      ({K, N, F}) ->
                         case proplists:get_all_values(K, Args) of
                             [] -> erlang:error({missing_option, K});
                             A -> {K, map_args(K, N, F, undefined, A)}
                         end
                 end, Opts) of
        Options -> {ok, Options}
    catch
        error:{missing_option, K} -> {missing_option, K};
        error:{parse_error, Reason, K, A} -> {parse_error, Reason, K, A}
    end.

log_exists(Log) ->
    {ok, Dir} = application:get_env(error_logger_mf_dir),
    log_exists(Dir, Log).

log_exists(Dir, Log) ->
    Path = filename:join(Dir, Log),
    IdxPath = lists:append(Path, ".idx"),

    filelib:is_regular(IdxPath).

stream_logs(Fn) ->
    stream_logs(?DEFAULT_LOG_FILENAME, Fn).

stream_logs(Log, Fn) ->
    {ok, Dir} = application:get_env(error_logger_mf_dir),
    stream_logs(Dir, Log, Fn).

stream_logs(Dir, Log, Fn) ->
    stream_logs(Dir, Log, Fn, 65536).

stream_logs(Dir, Log, Fn, ChunkSz) ->
    Path = filename:join(Dir, Log),

    {Ix, NFiles} = read_index_file(Path),
    Ixs = lists:seq(Ix + 1, NFiles) ++ lists:seq(1, Ix),

    lists:foreach(
      fun (LogIx) ->
              File = lists:append([Path, ".", integer_to_list(LogIx)]),
              case file:open(File, [raw, binary]) of
                  {ok, IO} ->
                      stream_logs_loop(IO, ChunkSz, Fn),
                      ok = file:close(IO);
                  _Other ->
                      ok
              end
      end,
      Ixs),

    Fn(<<"">>).

stream_logs_loop(IO, ChunkSz, Fn) ->
    case file:read(IO, ChunkSz) of
        eof ->
            ok;
        {ok, Data} ->
            Fn(Data),
            stream_logs_loop(IO, ChunkSz, Fn)
    end.

read_index_file(Path) ->
    {Ix, _, _, NFiles} = disk_log_1:read_index_file(Path),

    %% Index can be one greater than number of files. This means that maximum
    %% number of files is not yet reached.
    %%
    %% Pretty weird behavior: if we're writing to the first file out of 20
    %% read_index_file returns {1, _, _, 1}. But as we move to the second file
    %% the result becomes be {2, _, _, 1}.
    case Ix =:= NFiles + 1 of
        true ->
            {Ix, Ix};
        false ->
            {Ix, NFiles}
    end.
