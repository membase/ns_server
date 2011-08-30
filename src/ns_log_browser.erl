-module(ns_log_browser).

-define(report_types, [crash_report, supervisor_report, error, progress]).

-export([start/0]).
-export([get_logs/3, get_logs_as_file/3]).

-spec usage([1..255, ...], list()) -> no_return().
usage(Fmt, Args) ->
    io:format(Fmt, Args),
    usage().

-spec usage() -> no_return().
usage() ->
    io:format("Usage: <progname> [-n <max_reports>] [-e <regexp>] [-t <type>...]~n"
              "  where <type> is one of: ~w~n"
              "  You may specify more than one type; default is everything.~n",
              [?report_types]),
    halt(1).


map_types(TypeStrings) ->
    Types = lists:map(fun list_to_atom/1, TypeStrings),
    case lists:all(fun (T) -> lists:member(T, ?report_types) end, Types) of
        true -> Types;
        false -> usage("argument to -t must be one or more of ~w~n",
                       [?report_types])
    end.

start() ->
    Options = case parse_arguments([{h, 0, undefined, false},
                                    {n, 1, fun list_to_integer/1, all},
                                    {e, 1, undefined, undefined},
                                    {t, one_or_more, fun map_types/1, all},
                                    {report_dir, 1, undefined}],
                                   init:get_arguments()) of
                  {ok, O} ->
                      O;
                  {parse_error, badarg, n, _} ->
                      usage("-n requires a single integer argument~n", []);
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
    Types = proplists:get_value(t, Options),
    RegExp = proplists:get_value(e, Options),
    NumReports = proplists:get_value(n, Options),
    rb:start([{report_dir, Dir}, {type, Types}, {max, NumReports}]),
    case RegExp of
        undefined -> rb:show();
        E -> io:format("grepping for ~p~n", [E]), rb:grep(E)
    end.

get_logs_as_file(Types, NumReports, RegExp) ->
    catch rb:stop(),
    TempFile = path_config:tempfile("nslogs", ".log"),
    filelib:ensure_dir(TempFile),
    Options = [{start_log, TempFile}, {type, Types}, {max, NumReports}, {report_dir}],
    Options1 = case application:get_env(error_logger_mf_dir) of
                   undefined ->
                       Options;
                   {ok, LogDir} ->
                       [{report_dir, LogDir}|Options]
               end,
    case rb:start(Options1) of
        {ok, _Pid} -> ok;
        {error, already_present} ->
                                                % Can sometimes get wedged
            supervisor:delete_child(sasl_sup, rb_server),
            erlang:error(try_again);
        {error, Reason} ->
            erlang:error(Reason)
    end,
    case RegExp of
        [] -> rb:show();
        _ -> rb:grep(RegExp)
    end,
    catch rb:stop(),
    TempFile.

get_logs(Types, NumReports, RegExp) ->
    Filename = get_logs_as_file(Types, NumReports, RegExp),
    {ok, Data} = file:read_file(Filename),
    file:delete(Filename),
    Data.

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
