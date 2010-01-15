-module(stats_aggregator).

-behaviour(gen_server).

%% API
-export([start_link/0,
         received_data/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({received, _Hostname, _Port, _Stats} = Msg, State) ->
    error_logger:info_msg("Received some data:  ~p~n", [Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


received_data(Hostname, Port, Stats) ->
    gen_server:cast(received, Hostname, Port, Stats).
