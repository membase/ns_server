-module(stats_aggregator).

-behaviour(gen_server).

-define(SAMPLE_SIZE, 1800).

%% API
-export([start_link/0,
         monitoring/2,
         received_data/3,
         unmonitoring/2,
         get_stats/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {vals}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{vals=dict:new()}}.

handle_call({get, Hostname, Port, Count}, _From, State) ->
    Reply = ringdict:to_dict(Count,
                             dict:fetch({Hostname, Port},
                                        State#state.vals)),
    {reply, Reply, State}.

handle_cast({received, Hostname, Port, Stats}, State) ->
    error_logger:info_msg("Received some data:  ~p:~p (~p)~n",
                          [Hostname, Port, dict:to_list(Stats)]),
    {noreply, State#state{vals=dict:update({Hostname, Port},
                                           fun(R) ->
                                                   ringdict:add(Stats, R)
                                           end,
                                           State#state.vals)}};
handle_cast({monitoring, Hostname, Port}, State) ->
    error_logger:info_msg("Beginning to monitor:  ~p:~p~n",
                          [Hostname, Port]),
    {noreply, State#state{vals=dict:store({Hostname, Port},
                                          ringdict:new(?SAMPLE_SIZE),
                                          State#state.vals)}};
handle_cast({unmonitoring, Hostname, Port}, State) ->
    error_logger:info_msg("No longer monitoring:  ~p:~p~n",
                          [Hostname, Port]),
    {noreply, State#state{vals=dict:erase({Hostname, Port},
                                          State#state.vals)}}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


received_data(Hostname, Port, Stats) ->
    gen_server:cast(?MODULE, {received, Hostname, Port, Stats}).

monitoring(Hostname, Port) ->
    gen_server:cast(?MODULE, {monitoring, Hostname, Port}).

unmonitoring(Hostname, Port) ->
    gen_server:cast(?MODULE, {unmonitoring, Hostname, Port}).

get_stats(Hostname, Port, Count) ->
    gen_server:call(?MODULE, {get, Hostname, Port, Count}).
