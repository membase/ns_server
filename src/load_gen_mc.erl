-module(load_gen_mc).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_binary, [send/2, send/4, send_recv/5, recv/2]).

-compile(export_all).

start(feeder, McHost, McPort, NConns, N) ->
    start(feeder, McHost, McPort, NConns, N, self()).

start(feeder, _McHost, _McPort, _NConns, 0, _LoadGenPid) -> ok;
start(feeder, McHost, McPort, NConns, N, LoadGenPid) ->
    spawn(fun () ->
              LoadGenPid ! {request, {connect, McHost, McPort, NConns}},
              LoadGenPid ! {request, {work, all, unused}},
              LoadGenPid ! input_complete
          end),
    start(feeder, McHost, McPort, NConns, N - 1, LoadGenPid).

% --------------------------------------------------------

start(results) -> results_loop().

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
        {request, _From, {connect, McHost, McPort, NConns}} ->
            MoreSocks =
                lists:map(
                  fun (_X) ->
                      case gen_tcp:connect(McHost, McPort,
                                           [binary, {packet, 0},
                                            {active, false}]) of
                          {ok, Sock} -> Sock
                      end
                  end,
                  lists:seq(1, NConns)),
            request_loop(MoreSocks ++ Socks, Workers);

        {request, _From, {work, all, Args}} ->
            MoreWorkers = spawn_workers(Socks, Args),
            request_loop([], MoreWorkers ++ Workers);

        {request, _From, {work, N, Args}} ->
            {WorkerSocks, RemainingSocks} =
                lists:split(erlang:min(N, length(Socks)), Socks),
            MoreWorkers = spawn_workers(WorkerSocks, Args),
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

spawn_workers(Socks, Args) ->
    lists:map(fun (Sock) -> spawn(fun () -> loop(Sock, Args) end) end,
              Socks).

loop(Sock, N) ->
    receive
        stop -> ok
    after 0 ->
        {ok, _H, _E} = mc_client_binary:cmd(?NOOP, Sock, undefined, blank_he()),
        loop(Sock, N + 1)
    end.

blank_he() ->
    {#mc_header{}, #mc_entry{}}.

