-module(load_gen_mc).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

main()        -> main("127.0.0.1", 11211, get_miss, 1).
main([Story]) -> main("127.0.0.1", 11211, Story, 1);

% Example command-line usage:
%
%  erl -pa ebin load_gen_mc main 127.0.0.1 11211 get_miss 1
%
main([Host, Port, Story, NConns]) ->
    main(atom_to_list(Host),
         list_to_integer(atom_to_list(Port)),
         Story,
         list_to_integer(atom_to_list(NConns))).

main(Host, Port, Story, NConns) ->
    {ok, FeederPid} = start_feeder(Host, Port, NConns, Story),
    {ok, ResultPid} = start_results(),
    load_gen:start(load_gen_mc, FeederPid, ResultPid).

% --------------------------------------------------------

start_feeder(McHost, McPort, NConns, Story) ->
    start_feeder(McHost, McPort, NConns, Story, self()).

start_feeder(McHost, McPort, NConns, Story, LoadGenPid) ->
    FeederPid = spawn(fun () ->
                          LoadGenPid ! {request, {connect, McHost, McPort, NConns}},
                          LoadGenPid ! {request, {work, all, Story}},
                          LoadGenPid ! input_complete
                      end),
    {ok, FeederPid}.

% --------------------------------------------------------

start_results() -> {ok, spawn(fun results_loop/0)}.

results_loop() ->
    receive
        {result, _Outstanding, _FromNode, _Req, Response} ->
            ?debugVal(Response),
            results_loop();
        {result_progress, _Outstanding, _FromNode, _Req, Progress} ->
            ?debugVal(Progress),
            results_loop();
        done -> ok
    end.

% --------------------------------------------------------

init() -> request_loop([], []).

request_loop(Socks, Workers) ->
    receive
        {request, From, {connect, McHost, McPort, NConns} = Req} ->
            MoreSocks =
                lists:map(
                  fun (_X) ->
                      case gen_tcp:connect(McHost, McPort,
                                           [binary, {packet, 0},
                                            {active, false}]) of
                          {ok, Sock} -> Sock;
                          Error      -> From ! {response, self(), Req, Error}
                      end
                  end,
                  lists:seq(1, NConns)),
            request_loop(MoreSocks ++ Socks, Workers);

        {request, From, {work, all, Args} = Req} ->
            MoreWorkers = spawn_workers(From, Req, Socks, Args),
            request_loop([], MoreWorkers ++ Workers);

        {request, From, {work, N, Args} = Req} ->
            {WorkerSocks, RemainingSocks} =
                lists:split(erlang:min(N, length(Socks)), Socks),
            MoreWorkers = spawn_workers(From, Req, WorkerSocks, Args),
            request_loop(RemainingSocks, MoreWorkers ++ Workers);

        {request, _From, stop} ->
            stop_workers(Workers),
            request_loop(Socks, []);

        done -> stop_workers(Workers),
                ok
    end.

stop_workers([])              -> ok;
stop_workers([Worker | Rest]) -> Worker ! stop,
                                 stop_workers(Rest).

spawn_workers(From, Req, Socks, Args) ->
    lists:map(fun (Sock) ->
                  spawn(fun () ->
                            loop(From, Req, Sock, 1, Args)
                        end)
              end,
              Socks).

loop(From, Req, Sock, N, Args) ->
    case N rem 1000 of
        0 -> From ! {response_progress, self(), Req, N};
        _ -> ok
    end,
    receive
        stop -> ok
    after 0 ->
        ok = story(Sock, Args),
        loop(From, Req, Sock, N + 1, Args)
    end.

blank_he() ->
    {#mc_header{}, #mc_entry{}}.

story(Sock, noop) ->
    {ok, _H, _E} =
        mc_client_binary:cmd(?NOOP, Sock, undefined, blank_he()),
    ok;

story(Sock, get_miss) ->
    {error, _H, _E} =
        mc_client_binary:cmd(?GET, Sock, undefined,
                             {#mc_header{},
                              #mc_entry{key = <<"not_a_real_key">>}}),
    ok;

story(Sock, get_op) ->
    story(Sock,get_op,"Akey");

story(Sock, set) ->
    story(Sock,set,"Akey");

%TODO I am sure there is a way to do these w/o the hard-coded arrays
story(Sock, get_set) ->
  Keys=["key1","key2","key3","key4","key5","key6","key7","key8","key9","key10"],
  Ops=[set,get_op,get_op,get_op,get_op,get_op,get_op,get_op,get_op,get_op],
  Selected_key=lists:nth(random:uniform(10),Keys),
  Selected_op=lists:nth(random:uniform(10),Ops),
  story(Sock,Selected_op,Selected_key),
  ok.

story(Sock, set, Key) ->
        {ok, _H, _E} = mc_client_binary:cmd(?SET, Sock, undefined,
                           {#mc_header{},
                            #mc_entry{key = Key, data = string:concat(Key,<<"AAA">>)}}),
   ok;

story(Sock, get_op,Key) ->
    _RES =
        mc_client_binary:cmd(?GETK, Sock, undefined,
                             {#mc_header{},
                              #mc_entry{key = Key}}),
    ok.


