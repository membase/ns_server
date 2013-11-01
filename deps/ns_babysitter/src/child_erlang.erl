-module(child_erlang).

-include("ns_common.hrl").

-export([arguments_to_args/1,
         child_start/1,
         open_port_args/0]).

get_ns_server_vm_extra_args() ->
    case os:getenv("COUCHBASE_NS_SERVER_VM_EXTRA_ARGS") of
        false ->
            [];
        Value ->
            PV = case erl_scan:string(Value ++ ".") of
                     {ok, Ts, _} ->
                         case erl_parse:parse_term(Ts) of
                             {ok, Term0} when is_list(Term0) ->
                                 {ok, Term0};
                             Err0 ->
                                 {parse_error, Err0}
                         end;
                     Err0 ->
                         {scan_error, Err0}
                 end,
            case PV of
                {ok, Term} ->
                    true = is_list(Term),
                    Term;
                Err ->
                    ?log_warning("Got something in COUCHBASE_NS_SERVER_VM_EXTRA_ARGS environment variable (~s) but it's not a list term: ~p",
                                 [Value, Err]),
                    []
            end
    end.

open_port_args() ->
    AppArgs = arguments_to_args(init:get_arguments()),
    ErlangArgs = ["+A" , "16",
                  "-smp", "enable",
                  "+sbt",  "u",
                  "+P", "327680",
                  "+K", "true",
                  "+swt", "low",
                  "+MMmcs", case os:getenv("COUCHBASE_MSEG_CACHE_SIZE") of
                                false -> "30";
                                MCS ->
                                    MCS
                            end,
                  "-setcookie", "nocookie",
                  "-kernel", "inet_dist_listen_min", "21100", "inet_dist_listen_max", "21299",
                  "error_logger", "false",
                  "-sasl", "sasl_error_logger", "false",
                  "-nouser",
                  "-run", "child_erlang", "child_start", "ns_bootstrap"]
        ++ get_ns_server_vm_extra_args() ++ ["--"],
    AllArgs = ErlangArgs ++ AppArgs,
    ErlPath = filename:join([hd(proplists:get_value(root, init:get_arguments())),
                             "bin", "erl"]),
    [{spawn_executable, ErlPath},
     [{args, AllArgs},
      {env, [{"NS_SERVER_BABYSITTER_COOKIE", atom_to_list(erlang:get_cookie())}]},
      exit_status, use_stdio, stream, eof]].

child_start(Arg) ->
    try
        do_child_start(Arg)
    catch T:E ->
            io:format("Crap ~p:~p~n~p~n", [T, E, erlang:get_stacktrace()]),
            (catch ?log_debug("Crap to start:  ~p:~p~n~p~n", [T, E, erlang:get_stacktrace()])),
            timer:sleep(1000),
            erlang:halt(3)
    end.

do_child_start([ModuleToBootAsString]) ->
    case erlang:pid_to_list(erlang:group_leader()) of
        "<0.0.0>" ->
            %% we're doing nouser. Without user io:format will
            %% actually stuck, so we're making group_leader() be
            %% standard_error so that at least io:format works
            StdErr = erlang:whereis(standard_error),
            {true, have_stderr} = {StdErr =/= undefined, have_stderr},
            erlang:group_leader(StdErr, self()),
            erlang:group_leader(StdErr, erlang:whereis(application_controller));
        _ ->
            ok
    end,
    BootModule = list_to_atom(ModuleToBootAsString),
    BootModule:start(),
    %% NOTE: win32 support in erlang handles {fd, 0, 1} specially and
    %% does the right thing. {fd, 0, 0} would not work for example
    Port = erlang:open_port({fd, 0, 1}, [in, stream, binary, eof]),
    child_loop(Port, BootModule).

child_loop_quick_exit(BootModule) ->
    io:format("EOF. Exiting\n"),
    try BootModule:get_quick_stop() of
        Fn ->
            Fn()
    catch _T:_E -> ignore
    end,
    erlang:halt(0).

child_loop(Port, BootModule) ->
    ?log_debug("Entered child_loop"),
    receive
        {Port, {data, <<"shutdown\n">>}} ->
            io:format("got shutdown request. Exiting\n"),
            ?log_debug("Got EOL"),
            BootModule:stop(),
            ?log_debug("Got EOL: after ~s:stop()", [BootModule]),
            erlang:halt(0);
        {Port, eof} ->
            (catch ?log_debug("Got EOF")),
            child_loop_quick_exit(BootModule);
        {Port, {data, <<"die!\n">>}} ->
            (catch ?log_debug("Got die!")),
            child_loop_quick_exit(BootModule);
        {Port, {data, Msg}} ->
            io:format("--------------~n!!! Message from parent: ~s~n------------~n~n", [Msg]),
            (catch ?log_debug("--------------~n!!! Message from parent: ~s~n------------~n~n", [Msg])),
            BootModule:stop(),
            erlang:halt(0);
        Unexpected ->
            io:format("Got unexpected message: ~p~n", [Unexpected]),
            (catch ?log_debug("Got unexpected message: ~p~n", [Unexpected])),
            timer:sleep(3000),
            erlang:halt(1)
    end.

arguments_to_args([{Flag, Values} | RestArguments]) ->
    RestArgs = arguments_to_args(RestArguments),
    case Flag of
        root ->
            RestArgs;
        home ->
            RestArgs;
        progname ->
            RestArgs;
        name ->
            RestArgs;
        hidden ->
            RestArgs;
        setcookie ->
            RestArgs;
        detach ->
            RestArgs;
        noinput ->
            RestArgs;
        noshell ->
            RestArgs;
        nouser ->
            RestArgs;
        _ ->
            FlagStr = "-" ++ atom_to_list(Flag),
            [FlagStr | Values] ++ RestArgs
    end;
arguments_to_args([]) ->
    [].
