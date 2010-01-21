%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(ns_log).

-include("ns_log.hrl").

% Number of recent log entries.
-define(RB_SIZE, 50).

-behaviour(gen_server).
-behavior(ns_log_categorizing).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([log/3, log/4, recent/0, recent/1, recent_by_category/0, clear/0]).

-export([categorize/2, code_string/2]).

-export([ns_log_cat/1, ns_log_code_string/1]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {recent}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #state{recent=emptyRecent()}}.

emptyRecent() ->
    ringbuffer:new(?RB_SIZE).

% Request for recent items.
handle_call(recent, _From, State) ->
    Reply = ringbuffer:to_list(State#state.recent),
    {reply, Reply, State}.

% Inbound logging request.
handle_cast({log, Module, Code, Fmt, Args}, State) ->
    error_logger:info_msg("Logging ~p:~p(~p, ~p)~n",
                          [Module, Code, Fmt, Args]),
    NR = ringbuffer:add(#log_entry{module=Module, code=Code, msg=Fmt, args=Args,
                                   cat=categorize(Module, Code),
                                   tstamp=erlang:now()},
                        State#state.recent),
    {noreply, State#state{recent=NR}};
handle_cast(clear, _State) ->
    error_logger:info_msg("Clearing log.~n", []),
    {noreply,  #state{recent=emptyRecent()}}.
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

-spec categorize(atom(), integer()) -> log_classification().
categorize(Module, Code) ->
    case catch(Module:ns_log_cat(Code)) of
        info -> info;
        warn -> warn;
        crit -> crit;
        _ -> info % Anything unknown is info (this includes {'EXIT', Reason})
        end.

-spec code_string(atom(), integer()) -> string().
code_string(Module, Code) ->
    case catch(Module:ns_log_code_string(Code)) of
        S when is_list(S) -> S;
        _                 -> "message"
    end.

% A Code is an number which is module-specific.
%
-spec log(atom(), integer(), string()) -> ok.
log(Module, Code, Msg) ->
    log(Module, Code, Msg, []).

-spec log(atom(), integer(), string(), list()) -> ok.
log(Module, Code, Fmt, Args) ->
    gen_server:cast(?MODULE, {log, Module, Code, Fmt, Args}).

-spec recent() -> list(#log_entry{}).
recent() ->
    gen_server:call(?MODULE, recent).

-spec recent(atom()) -> list(#log_entry{}).
recent(Module) ->
    lists:usort([E || E <- gen_server:call(?MODULE, recent),
                     E#log_entry.module =:= Module ]).

% {crit, warn, info}
-spec recent_by_category() -> {list(#log_entry{}),
                               list(#log_entry{}),
                               list(#log_entry{})}.
recent_by_category() ->
    lists:foldl(fun(E, {C, W, I}) ->
                        case E#log_entry.cat of
                            crit -> {[E | C], W, I};
                            warn -> {C, [E | W], I};
                            info -> {C, W, [E | I]}
                        end
                end,
                {[], [], []},
                recent()).

-spec clear() -> ok.
clear() ->
    gen_server:cast(?MODULE, clear).


% Example categorization -- pretty much exists for the test below, but
% this is what any module that logs should look like.
ns_log_cat(1) ->
    crit;
ns_log_cat(2) ->
    warn;
ns_log_cat(3) ->
    info.

ns_log_code_string(1) ->
    "logging could not foobar";
ns_log_code_string(2) ->
    "logging hit max baz".

% ------------------------------------------

log_test() ->
    ok = log(?MODULE, 1, "not ready log"),

    {ok, Pid} = gen_server:start({local, ?MODULE}, ?MODULE, [], []),
    ok = log(?MODULE, 1, "test log 1"),
    ok = log(?MODULE, 2, "test log 2 ~p ~p", [x, y]),
    ok = log(?MODULE, 3, "test log 3 ~p ~p", [x, y]),
    ok = log(?MODULE, 4, "test log 4 ~p ~p", [x, y]),

    {C, W, I} = recent_by_category(),
    ["test log 1"] = [E#log_entry.msg || E <- C],
    ["test log 2 ~p ~p"] = [E#log_entry.msg || E <- W],
    ["test log 4 ~p ~p", "test log 3 ~p ~p"] = [E#log_entry.msg || E <- I],

    exit(Pid, exiting),
    ok.
