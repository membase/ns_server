-module(stats_collection_clock).

% This is a launcher for a gen_event instance that sends out an event
% on a specific interval.

-define(FREQUENCY, 1000).

%% API
-export([start_link/0, start_link/1, collect/0]).

start_link() ->
    start_link(?FREQUENCY).

start_link(Frequency) ->
    {ok, Pid} = gen_event:start_link({local, ?MODULE}),
    {ok, _Tref} = timer:apply_interval(Frequency, ?MODULE, collect, []),
    {ok, Pid}.

% Collect is called whenever it's time to do a collection.
collect() ->
    ok = gen_event:notify(?MODULE, collect).
