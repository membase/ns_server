% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.
%%%-------------------------------------------------------------------
%%% File    : stats_aggregator_manager.erl
%%% Author  : Aliaksey Kandratsenka <alk@tut.by>
%%% Description : manager and directory of stats aggregators, actually
%%% this works as generic directory of processes.
%%%
%%% Created :  5 Jan 2010 by Aliaksey Kandratsenka <alk@tut.by>
%%%-------------------------------------------------------------------
-module(stats_aggregator_manager).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0, spawn_test_aggregator_process/2]).
-endif.

%% API
-export([start_link/1, start_link/0, just_start/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([get_aggregator_for/1, kill_childs/0, call_aggregator_for/3, call_aggregator_for/2]).

-record(state, {ets_map, aggregator_spawn_args, by_mref}).

get_aggregator_for(BucketName) ->
    gen_server:call(?MODULE, {get_aggregator_for, BucketName}).

%% should be called on config changes
kill_childs() ->
    gen_server:call(?MODULE, kill_childs).

call_aggregator_for(BucketName, Args) ->
    call_aggregator_for(BucketName, {gen_server, call}, Args).

call_aggregator_for(BucketName, Caller, Args) ->
    Rec = fun (Self, TimesLeft) ->
                  Pid = get_aggregator_for(BucketName),
                  try
                      case Caller of
                          {Module, F} -> Module:F(Pid, Args);
                          F when is_function(F) -> F(Pid, Args)
                      end
                  catch
                      exit:{no_proc, _}=E ->
                          case TimesLeft-1 of
                              0 -> exit(E);
                              T -> Self(Self, T)
                          end;
                      exit:{aggregator_respawn, _} -> Self(Self, TimesLeft)
                  end
          end,
    Rec(Rec, 5).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link(AggregatorSpawnArgs) -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(AggregatorSpawnArgs) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [AggregatorSpawnArgs], []).

start_link() ->
    start_link([[stats_aggregator, start, []]]).

just_start() ->
    io:format("starting~n"),
    RV = gen_server:start({local, ?MODULE}, ?MODULE, [[stats_aggregator, start, []]], []),
    io:format("done~n"),
    RV.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([[_Module, _Fun, _ExtraArgs] = AggregatorSpawnArgs])->
    {ok, #state{ets_map = ets:new(ets_map, []),
                aggregator_spawn_args = AggregatorSpawnArgs,
                by_mref = ets:new(by_mref, [{keypos, 3}])}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({get_aggregator_for, BucketName}, _From, State) ->
    Pid = case ets:lookup(State#state.ets_map, BucketName) of
              [{_, P, _}=Tuple] ->
                  case is_process_alive(P) of
                      true -> P;
                      false -> cleanup_dead_aggregator(Tuple, State),
                               spawn_child_aggregator(BucketName, State)
                  end;
              [] -> spawn_child_aggregator(BucketName, State)
          end,
    {reply, Pid, State};
handle_call(kill_childs, _From, State) ->
    ets:foldl(fun ({_, Pid, MRef}, _) ->
                      erlang:demonitor(MRef, [flush]),
                      exit(Pid, aggregator_respawn),
                      true
              end, true, State#state.ets_map),
    ets:delete_all_objects(State#state.ets_map),
    ets:delete_all_objects(State#state.by_mref),
    {reply, ok, State}.

spawn_child_aggregator(BucketName, State) ->
    [Module, Fun, ExtraArgs] = State#state.aggregator_spawn_args,
    {ok, P} = apply(Module, Fun, [BucketName | ExtraArgs]),
    MRef = erlang:monitor(process, P),
    Tuple = {BucketName, P, MRef},
    ets:insert(State#state.ets_map, Tuple),
    ets:insert(State#state.by_mref, Tuple),
    P.

cleanup_dead_aggregator(Tuple, State) ->
    true = ets:delete_object(State#state.ets_map, Tuple),
    true = ets:delete_object(State#state.by_mref, Tuple).

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({'DOWN', MRef, process, _Item, _Info}=All, State) ->
    ns_log:log(?MODULE, 1, "Got DOWN for %p", [All]),
    case ets:lookup(State#state.by_mref, MRef) of
        [{BucketName, _, _}=Tuple] ->
            ns_log:log(?MODULE, 2, "Aggregator for bucket ~p is down", [BucketName]),
            cleanup_dead_aggregator(Tuple, State);
        [] ->
            ns_log:log(?MODULE, 3, "DOWN is for unknown aggregator. Ignoring")
    end,
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-ifdef(EUNIT).

test_aggregator_process(BucketName, Parent) ->
    receive
        {die} -> ok;
        {T, F} -> F ! {T, self()},
                  test_aggregator_process(BucketName, Parent)
    end.

spawn_test_aggregator_process(BucketName, Parent) ->
    {ok, spawn(fun () ->
                  test_aggregator_process(BucketName, Parent)
          end)}.

test_setup() ->
    start_link([?MODULE, spawn_test_aggregator_process, [self()]]).

test_teardown(_V) ->
    t.

test() ->
    eunit:test({spawn, {setup,
                        fun () -> test_setup() end,
                        fun (V) -> test_teardown(V) end,
                        {module, ?MODULE}}}, [verbose]).

assert_receive(Timeout) ->
    receive
        M -> M
    after Timeout -> exit(timeout)
    end.

basic_test() ->
    %% check child is born and that it's functional
    call_aggregator_for("test1", fun erlang:send/2, {ping, self()}),
    {ping, Pid} = assert_receive(500),

    %% now kill it brutally
    erlang:monitor(process, Pid),
    Pid ! {die},
    ?assertMatch({'DOWN', _, process, Pid, normal}, assert_receive(500)),

    %% and check that it's reborn
    PidTest1 = get_aggregator_for("test1"),
    ?assertNot(PidTest1 =:= Pid),
    %% also check that other bucket gets other child
    PidTest2 = get_aggregator_for("test2"),
    ?assert(PidTest1 =/= PidTest2),
    %% and check that repeating get_aggregator_for returns existing child
    ?assertEqual(get_aggregator_for("test2"), PidTest2),
    ?assertEqual(get_aggregator_for("test1"), PidTest1),
    % check that both childs are functional
    PidTest1 ! {ping, self()},
    PidTest2 ! {ping, self()},
    case {assert_receive(500), assert_receive(500)} of
        {{ping, PidTest1},
         {ping, PidTest2}} -> ok;
        {{ping, PidTest2},
         {ping, PidTest1}} -> ok
    end,

    %% now kill everyone
    kill_childs(),

    %% and check that new childs are born
    ?assertNot(get_aggregator_for("test1") =:= PidTest1),
    ?assertNot(get_aggregator_for("test2") =:= PidTest2),
    %% verify that all messages were expected
    receive
        M2 -> ?assert("unknown msg" =/= M2)
    after 100 -> ok
    end.

-endif.
