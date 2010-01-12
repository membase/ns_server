-module(ns_log).

% Number of recent log entries.
-define(RB_SIZE, 50).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([log/3, log/4, recent/0]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {recent}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{recent=queue:from_list([ empty || _ <- lists:seq(1, ?RB_SIZE)])}}.

% Request for recent items.
handle_call(recent, _From, State) ->
    Reply = queue:to_list(
              queue:filter(fun(X) -> X =/= empty end, State#state.recent)),
    {reply, Reply, State}.

% Inbound logging request.
handle_cast({log, Module, Code, Fmt, Args}, State) ->
    error_logger:info_msg("Logging ~p:~p(~p, ~p)~n",
                          [Module, Code, Fmt, Args]),
    {{value, _Ignored}, Qtmp} = queue:out(State#state.recent),
    NewQ = queue:in({Module, Code, Fmt, Args}, Qtmp),
    {noreply, State#state{recent=NewQ}}.
% Not handling any other state.


% Nothing special.
handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% API

% A Code is an number which is module-specific.
%
-spec log(atom(), integer(), string()) -> ok.
log(Module, Code, Msg) ->
    log(Module, Code, Msg, []).

-spec log(atom(), integer(), string(), list()) -> ok.
log(Module, Code, Fmt, Args) ->
    gen_server:cast(?MODULE, {log, Module, Code, Fmt, Args}).

-spec recent() -> list({atom(), integer(), string(), list()}).
recent() ->
    gen_server:call(?MODULE, recent).

% TODO: Implement this placeholder api, possibly as a gen_server
%       to track the last few log msgs in memory.  A client then might
%       want to do a rpc:multicall to gather all the recent log entries.

% ------------------------------------------

log_test() ->
    ok = log(?MODULE, 1, "test log"),
    ok = log(?MODULE, 2, "test log ~p ~p", [x, y]),
    ok.
