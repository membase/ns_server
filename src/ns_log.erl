%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(ns_log).

-include("ns_log.hrl").

-define(RB_SIZE, 100). % Number of recent log entries
-define(DUP_TIME, 300000000). % 300 secs in microsecs
-define(GC_TIME, 60000). % 60 secs in millisecs
-define(SAVE_DELAY, 5000). % 5 secs in millisecs

-behaviour(gen_server).
-behaviour(ns_log_categorizing).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([log/3, log/4, recent/0, recent/1]).

-export([categorize/2, code_string/2]).

-export([ns_log_cat/1, ns_log_code_string/1]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {recent, dedup, save_tref, filename}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    timer:send_interval(?GC_TIME, garbage_collect),
    Filename = ns_config:search_node_prop(ns_config:get(), ns_log, filename),
    Recent = case file:read_file(Filename) of
                 {ok, <<>>} -> [];
                 {ok, B} -> binary_to_term(zlib:uncompress(B));
                 E ->
                     error_logger:info_msg(
                       "~p:init(): Couldn't load logs from ~p: ~p~n",
                       [?MODULE, Filename, E]),
                     []
             end,
    {ok, #state{recent=Recent, dedup=dict:new(), filename=Filename}}.

% Request for recent items.
handle_call(recent, _From, State) ->
    {reply, State#state.recent, State}.

% Inbound logging request.
handle_cast({log, Module, Code, Fmt, Args}, State = #state{dedup=Dedup}) ->
    Now = erlang:now(),
    Key = {Module, Code, Fmt, Args},
    case dict:find(Key, Dedup) of
        {ok, {Count, FirstSeen, LastSeen}} ->
            error_logger:info_msg("ns_log: suppressing duplicate log ~p:~p(~p) because it's been "
                                  "seen ~p times in the past ~p secs (last seen ~p secs ago~n",
                                  [Module, Code, lists:flatten(io_lib:format(Fmt, Args)),
                                   Count+1, timer:now_diff(Now, FirstSeen) / 1000000,
                                   timer:now_diff(Now, LastSeen) / 1000000]),
            Dedup2 = dict:store(Key, {Count+1, FirstSeen, Now}, Dedup),
            {noreply, State#state{dedup=Dedup2}};
        error ->
            Category = categorize(Module, Code),
            Entry = #log_entry{node=node(), module=Module, code=Code, msg=Fmt,
                               args=Args, cat=Category, tstamp=Now},
            gen_server:abcast(?MODULE, {do_log, Entry}),
            try gen_event:notify(ns_log_events, {ns_log, Category, Module, Code,
                                                 Fmt, Args})
            catch _:Reason ->
                    error_logger:error_msg("ns_log: unable to notify listeners "
                                           "because of ~p~n", [Reason])
            end,
            Dedup2 = dict:store(Key, {0, Now, Now}, Dedup),
            {noreply, State#state{dedup=Dedup2}}
    end;
handle_cast({do_log, Entry}, State = #state{recent=Recent}) ->
    {noreply, schedule_save(State#state{recent=lists:usort([Entry|Recent])})};
handle_cast({sync, Compressed}, State = #state{recent=Recent}) ->
    case binary_to_term(zlib:uncompress(Compressed)) of
        Recent ->
            {noreply, State};
        Logs ->
            State1 = schedule_save(State),
            {noreply, State1#state{recent=lists:sublist(
                                            lists:umerge(Recent, Logs),
                                            ?RB_SIZE)}}
    end.

% Not handling any other state.

% Nothing special.
handle_info(garbage_collect, State) ->
    misc:flush(garbage_collect),
    {noreply, gc(State)};
handle_info(sync, State = #state{recent=Recent}) ->
    timer:send_after(5000 + random:uniform(55000), sync),
    Nodes = ns_node_disco:nodes_actual_other(),
    Node = lists:nth(random:uniform(length(Nodes)), Nodes),
    gen_server:cast({?MODULE, Node}, {sync, zlib:compress(term_to_binary(Recent))}),
    {noreply, State};
handle_info(save, State = #state{filename=Filename, recent=Recent}) ->
    Compressed = zlib:compress(term_to_binary(Recent)),
    case file:write_file(Filename, Compressed) of
        ok -> ok;
        E ->
            error_logger:error_msg("~p: unable to write log to ~p: ~p~n",
                                   [?MODULE, Filename, E])
    end,
    {noreply, State#state{save_tref=undefined}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

gc(State = #state{dedup=Dupes}) ->
    DupesList = gc(erlang:now(), dict:to_list(Dupes),
                             []),
    State#state{dedup=dict:from_list(DupesList)}.

gc(_Now, [], DupesList) -> DupesList;
gc(Now, [{Key, Value} | Rest], DupesList) ->
     {Count, FirstSeen, _LastSeen} = Value,
     case timer:now_diff(Now, FirstSeen) >= ?DUP_TIME of
     true ->
         {Module, Code, Fmt, Args} = Key,
         case Count of
             0 -> ok;
             _ ->
                 Entry = #log_entry{node=node(), module=Module,
                                    code=Code,
                                    msg=Fmt ++ " (repeated ~p times)",
                                    args=Args ++ [Count],
                                    cat=categorize(Module, Code),
                                    tstamp=Now},
                 gen_server:abcast(?MODULE, {do_log, Entry})
         end,
         gc(Now, Rest, DupesList);
     false -> gc(Now, Rest, [{Key, Value} | DupesList])
     end.

schedule_save(State = #state{save_tref=undefined}) ->
    {ok, TRef} = timer:send_after(?SAVE_DELAY, save),
    State#state{save_tref=TRef};
schedule_save(State) ->
    %% Don't reschedule if a save is already scheduled.
    State.


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
    error_logger:info_msg("ns_log: logging ~p:~p:~s~n",
                          [Module, Code, lists:flatten(io_lib:format(Fmt, Args))]),
    gen_server:cast(?MODULE, {log, Module, Code, Fmt, Args}).

-spec recent() -> list(#log_entry{}).
recent() ->
    gen_server:call(?MODULE, recent).

-spec recent(atom()) -> list(#log_entry{}).
recent(Module) ->
    [E || E <- gen_server:call(?MODULE, recent),
          E#log_entry.module =:= Module ].

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

    {ok, Pid} = gen_server:start(?MODULE, [], []),
    ok = log(?MODULE, 1, "test log 1"),
    ok = log(?MODULE, 2, "test log 2 ~p ~p", [x, y]),
    ok = log(?MODULE, 3, "test log 3 ~p ~p", [x, y]),
    ok = log(?MODULE, 4, "test log 4 ~p ~p", [x, y]),

    exit(Pid, exiting),
    ok.
