% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(load_gen_mc).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).


main()        -> main("127.0.0.1", 11211, get_set, small, 1).
main([Story]) -> main("127.0.0.1", 11211, Story, small, 1);

% Example command-line usage:
%
%  erl -pa ebin load_gen_mc main 127.0.0.1 11211 get_miss 1
%
main([Host, Port, OpType, Size, NConns]) ->
    main(atom_to_list(Host),
         list_to_integer(atom_to_list(Port)),
         OpType,
         Size,
         list_to_integer(atom_to_list(NConns))).

main(Host, Port, OpType, Size, NConns) ->
    {ok, FeederPid} = start_feeder(Host, Port, NConns, OpType, Size),
    {ok, ResultPid} = start_results(),
    load_gen:start(load_gen_mc, FeederPid, ResultPid).

% --------------------------------------------------------

start_feeder(McHost, McPort, NConns, OpType, Size) ->
    start_feeder(McHost, McPort, NConns, OpType, Size, self()).

start_feeder(McHost, McPort, NConns, Story, Size, LoadGenPid) ->
    Env = {Story,Size},
    FeederPid = spawn(fun () ->
                          LoadGenPid ! {request, {connect, McHost, McPort, NConns}},
                          LoadGenPid ! {request, {work, all, Env}},
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

story(Sock,Args) ->
  {Ops, EntrySize} = Args,
  case Ops of
    set -> story(Sock,set,generateDataSize(EntrySize));
    get_op -> story(Sock,get_op,generateDataSize(EntrySize));
    get_miss -> story(Sock,get_miss);
    get_set ->
      SelectedOp = case random:uniform(90) rem 9 of
        0 -> set;
        _ -> get_op
      end,
      story(Sock,{SelectedOp,EntrySize});
    noop -> story(Sock,noop);
    _ -> io:format("Unknown opertation type ~p~n",[Ops])
  end.

story(Sock, set, Size) ->
  Bits = Size * 8,
  Key = term_to_binary(io_lib:format("Key~p",[Size])),
  {ok, _H, _E} = mc_client_binary:cmd(?SET, Sock, undefined,
                 {#mc_header{},
                  #mc_entry{key = Key, data = generateBits(<<16#deadbeef:32>>,Bits)}}),
   ok;

story(Sock, get_op,KeySuffix) ->
  Key = term_to_binary(io_lib:format("Key~p",[KeySuffix])),
  ExpectedEntry = generateBits(<<16#deadbeef:32>>,KeySuffix * 8),
  {Rc, _H, E} =
        mc_client_binary:cmd(?GETK, Sock,undefined,
                             {#mc_header{},
                              #mc_entry{key = Key}}),
  case Rc of
    ok -> ?assertMatch(Key,E#mc_entry.key),
          ?assertMatch(ExpectedEntry,E#mc_entry.data);
    _ -> ok
  end,
  ok.

generateDataSize(EntrySize) ->
  case EntrySize of
    small -> Range={768,1280};
    medium -> Range={7680,12800};
    large -> Range={768,1280};
    xlarge -> Range={786432,1048576}
  end,
  generateSize(Range).

generateSize({Min,Max}) ->
  Min + random:uniform(Max - Min).

generateBits(Pattern,Size) ->
  PatternSize = size(Pattern),
  Iters = Size div PatternSize,
  Rem = Size rem PatternSize,
  << (list_to_binary(lists:duplicate(Iters, Pattern)))/binary, (element(1,split_binary(Pattern,Rem)))/binary >>.

sasl_test(Sock,Mech,User,Password) ->
  {ok, _H, _E} = mc_client_binary:cmd(?CMD_SASL_AUTH, Sock, undefined,
                                      {#mc_header{},
                                       #mc_entry{key = Mech,
                                       data =  <<0:8,User,0:8,Password>>
                                      }}),
  ok.
