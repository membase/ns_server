-module(stats_aggregator).

-behaviour(gen_server).

-define(SAMPLE_SIZE, 1800).

%% API
-export([start_link/0,
         monitoring/3,
         received_data/5,
         unmonitoring/3,
         get_stats/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {vals}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{vals=dict:new()}}.

handle_call({get, Hostname, Port, Bucket, Count}, _From, State) ->
    Reply = ringdict:to_dict(Count,
                             dict:fetch({Hostname, Port, Bucket},
                                        State#state.vals)),
    {reply, Reply, State}.

handle_cast({received, T, Hostname, Port, Bucket, Stats}, State) ->
    error_logger:info_msg("Received some data:  ~s@~s:~p (~p)~n",
                          [Bucket, Hostname, Port, dict:to_list(Stats)]),
    TS = dict:store(t, T, Stats),
    {noreply, State#state{vals=dict:update({Hostname, Port, Bucket},
                                           fun(R) ->
                                                   ringdict:add(TS, R)
                                           end,
                                           State#state.vals)}};
handle_cast({monitoring, Hostname, Port, Bucket}, State) ->
    error_logger:info_msg("Beginning to monitor:  ~s@~s:~p~n",
                          [Bucket, Hostname, Port]),
    {noreply, State#state{vals=dict:store({Hostname, Port, Bucket},
                                          ringdict:new(?SAMPLE_SIZE),
                                          State#state.vals)}};
handle_cast({unmonitoring, Hostname, Port, Bucket}, State) ->
    error_logger:info_msg("No longer monitoring:  ~s@~s:~p~n",
                          [Bucket, Hostname, Port]),
    {noreply, State#state{vals=dict:erase({Hostname, Port},
                                          State#state.vals)}}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

received_data(T, Hostname, Port, Bucket, Stats) ->
    gen_server:cast(?MODULE, {received, T, Hostname, Port, Bucket, Stats}).

monitoring(Hostname, Port, Bucket) ->
    gen_server:cast(?MODULE, {monitoring, Hostname, Port, Bucket}).

unmonitoring(Hostname, Port, Bucket) ->
    gen_server:cast(?MODULE, {unmonitoring, Hostname, Port, Bucket}).

get_stats(Hostname, Port, Bucket, Count) ->
    gen_server:call(?MODULE, {get, Hostname, Port, Bucket, Count}).
