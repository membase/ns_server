%%%-------------------------------------------------------------------
%%% File    : stats_aggregator.erl
%%% Author  : Aliaksey Kandratsenka <alk@tut.by>
%%% Description : stats aggregator itself
%%%
%%% Created :  6 Jan 2010 by Aliaksey Kandratsenka <alk@tut.by>
%%%-------------------------------------------------------------------
-module(stats_aggregator).

-behaviour(gen_server).

%% API
-export([start/1, get_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {bucket_name,
                inactive_periods = 0,
                had_activity = false,
                stats,
                collector_pids}).

-define(SERVER, ?MODULE).

%% sampling period in milliseconds
-define(SAMPLING_PERIOD, 5000).
-define(COLLECTION_TIMEOUT, 5000).
-define(INACTIVE_PERIODS_TO_DEATH, 10).

get_stats(BucketName) ->
    stats_aggregator_manager:call_aggregator_for(BucketName, {gen_server, call}, {get_stats}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start(BucketName) -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start(BucketName) ->
    gen_server:start({local, ?SERVER}, ?MODULE, [BucketName], []).

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
init([BucketName]) ->
    %% NodeList = [node() | nodes()],
    NodeList = [node(), node(), node()], %% for easy testing for now
    ChildPids = lists:map(fun (Node) ->
                                  spawn_link(Node, stats_collector, loop, [fake_state])
                          end, NodeList),
    timer:send_after(?SAMPLING_PERIOD, sampling_timer),
    {ok, #state{bucket_name = BucketName,
                collector_pids = ChildPids}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({get_stats}, _From, State) ->
    Reply = State#state.stats,
    %% %% TODO: implement data processing
    %% Reply = multicollect(State#state.collector_pids),
    ns_log:log(?MODULE, 1, "returning stats ~p", [Reply]),
    {reply, Reply, State#state{had_activity = true}}.

%% grabs stats responses from pids in a list
%% does not waits, just grabs what's already in a queue
recv_nowait(Ref, Values, [Pid | RestCollectorPidsWait]) ->
    receive
        {grab_stats_res, Ref, Pid, Value} ->
            recv_nowait(Ref, [{ok, Pid, Value} | Values], RestCollectorPidsWait)
    after 0 ->
            recv_nowait(Ref, [{timeout, Pid} | Values], RestCollectorPidsWait)
    end;
recv_nowait(_Ref, Values, []) ->
    Values.

%% waits for grab_stats_res messages from child pids
%% if timeout comes earlier calls recv_nowait for remaining pids
recv_inner(TimerId, Ref, Values, [Pid | RestCollectorPidsWait]) ->
    receive
        {grab_stats_res, Ref, Pid, Value} ->
            recv_inner(TimerId, Ref, [{ok, Pid, Value} | Values], RestCollectorPidsWait);
        {timeout, TimerId, _} ->
            recv_nowait(Ref, Values, RestCollectorPidsWait)
    end;
recv_inner(_TimerId, _Ref, Values, []) ->
    Values.

multicollect(CollectorPids) ->
    Ref = make_ref(),
    Self = self(),
    lists:foreach(fun (Pid) -> Pid ! {grab_stats, Self, Ref} end,
                  CollectorPids),
    TimerId = erlang:start_timer(?COLLECTION_TIMEOUT, Self, ok),
    recv_inner(TimerId, Ref, [], CollectorPids).

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
handle_info(sampling_timer, #state{inactive_periods = InactivePeriods} = State) ->
    Stats = multicollect(State#state.collector_pids),
    ns_log:log(?MODULE, 1, "collected stats ~p", [Stats]),

    NewInactivePeriods = InactivePeriods+1,
    ns_log:log(stats_aggregator, 2, "inactivity"),

    NewState = State#state{inactive_periods = NewInactivePeriods,
                           stats = Stats},
    if
        NewInactivePeriods >= ?INACTIVE_PERIODS_TO_DEATH ->
            {stop, inactivity, NewState};
        true ->
            timer:send_after(?SAMPLING_PERIOD, sampling_timer),
            {noreply, NewState}
    end;
handle_info(_Info, State) ->
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
