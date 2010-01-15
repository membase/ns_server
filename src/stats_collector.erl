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
    lists:foreach(fun (Bucket) ->
                          stats_aggregator:monitoring(Hostname,
                                                      Port,
                                                      Bucket)
                  end, Buckets),
    {ok, #state{hostname=Hostname, port=Port, buckets=Buckets}}.

handle_event(collect, State) ->
    error_logger:info_msg("Collecting from ~p@~s:~p.~n",
                          [State#state.buckets,
                           State#state.hostname,
                           State#state.port]),
    {ok, State}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, State) ->
    lists:foreach(fun (Bucket) ->
                          stats_aggregator:unmonitoring(State#state.hostname,
                                                        State#state.port,
                                                        Bucket)
                  end, State#state.buckets),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%
%% Entry Points.
%

monitor(Hostname, Port, Buckets) ->
    ok = gen_event:add_handler(?SERVER, {?MODULE, {Hostname, Port}},
                               [Hostname, Port, Buckets]).

unmonitor(Hostname, Port) ->
    ok = gen_event:delete_handler(?SERVER, {?MODULE, {Hostname, Port}}, []).
