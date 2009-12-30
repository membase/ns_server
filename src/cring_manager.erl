-module(cring_manager).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-record(state, {cring}).

%% API

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
  gen_server:cast(?MODULE, stop).

cring(Bucket) ->
  gen_server:call(?MODULE, {cring, Bucket}).

%% gen_server callbacks

init([]) -> {ok, #state{}}.
terminate(_Reason, _State)          -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_info(_Info, State) -> {noreply, State}.
handle_cast(stop, State)  -> {stop, shutdown, State}.

handle_call({cring, _Bucket}, _From, #state{cring = CRing} = State) ->
    {reply, CRing, State}.
