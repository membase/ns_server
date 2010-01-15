-module(stats_collector).

-define(SERVER, stats_collection_clock).

-behaviour(gen_event).
%% API
-export([start_link/0,
         monitor/3, unmonitor/3]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {hostname, port, bucket}).

start_link() ->
    {error, "Don't start_link this."}.

init([Hostname, Port, Bucket]) ->
    {ok, #state{hostname=Hostname, port=Port, bucket=Bucket}}.

handle_event(collect, State) ->
    error_logger:info_msg("Collecting from ~p@~p:~p.~n",
                          [State#state.bucket,
                           State#state.hostname,
                           State#state.port]),
    {ok, State}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State}.

handle_info(_Info, State) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%
%% Entry Points.
%

monitor(Hostname, Port, Bucket) ->
    stats_aggregator:monitoring(Hostname, Port, Bucket),
    ok = gen_event:add_handler(?SERVER, {?MODULE, {Hostname, Port, Bucket}},
                               [Hostname, Port, Bucket]).

unmonitor(Hostname, Port, Bucket) ->
    ok = gen_event:delete_handler(?SERVER, {?MODULE, {Hostname, Port, Bucket}}, []),
    stats_aggregator:unmonitoring(Hostname, Port, Bucket).
