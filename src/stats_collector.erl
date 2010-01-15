-module(stats_collector).

-define(SERVER, stats_collection_clock).

-behaviour(gen_event).
%% API
-export([start_link/0,
         monitor/3, unmonitor/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {hostname, port, buckets}).

start_link() ->
    {error, "Don't start_link this."}.

init([Hostname, Port, Buckets]) ->
    notify_monitoring(Hostname, Port, Buckets),
    {ok, #state{hostname=Hostname, port=Port, buckets=Buckets}}.

handle_event(collect, State) ->
    error_logger:info_msg("Collecting from ~p@~s:~p.~n",
                          [State#state.buckets,
                           State#state.hostname,
                           State#state.port]),
    {ok, State}.

handle_call({set_buckets, Buckets}, State) ->
    Removed = State#state.buckets -- Buckets,
    Added = Buckets -- State#state.buckets,
    error_logger:info_msg("Added:  ~p, Removed:  ~p~n", [Added, Removed]),
    notify_monitoring(State#state.hostname, State#state.port, Added),
    notify_unmonitoring(State#state.hostname, State#state.port, Removed),
    {ok, ok, State#state{buckets=Buckets}}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, State) ->
    notify_unmonitoring(State#state.hostname, State#state.port,
                        State#state.buckets),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

notify_monitoring(Hostname, Port, Buckets) ->
    lists:foreach(fun (Bucket) ->
                          stats_aggregator:monitoring(Hostname,
                                                      Port,
                                                      Bucket)
                  end, Buckets).

notify_unmonitoring(Hostname, Port, Buckets) ->
        lists:foreach(fun (Bucket) ->
                          stats_aggregator:unmonitoring(Hostname,
                                                        Port,
                                                        Bucket)
                  end, Buckets).

%
%% Entry Points.
%

monitor(Hostname, Port, Buckets) ->
    case gen_event:call(?SERVER, {?MODULE, {Hostname, Port}},
                        {set_buckets, Buckets}) of
        {error, bad_module} ->
            ok = gen_event:add_handler(?SERVER, {?MODULE, {Hostname, Port}},
                                       [Hostname, Port, Buckets]);
        ok -> ok
    end.

unmonitor(Hostname, Port) ->
    ok = gen_event:delete_handler(?SERVER, {?MODULE, {Hostname, Port}}, []).
