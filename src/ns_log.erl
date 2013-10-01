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

-define(RB_SIZE, 3000). % Number of recent log entries
-define(DUP_TIME, 15000000). % 15 secs in microsecs
-define(GC_TIME, 60000). % 60 secs in millisecs
-define(SAVE_DELAY, 5000). % 5 secs in millisecs

-behaviour(gen_server).
-behaviour(ns_log_categorizing).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([start_link_crash_consumer/0]).

-export([log/6, log/7, recent/0, recent/1, delete_log/0]).

-export([code_string/2]).

-export([ns_log_cat/1, ns_log_code_string/1]).

-include_lib("eunit/include/eunit.hrl").
-include("ns_common.hrl").

-record(state, {unique_recent,
                dedup,
                save_tref,
                filename,
                pending_recent = [],
                pending_length = 0}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

start_link_crash_consumer() ->
    {ok, proc_lib:spawn_link(fun crash_consumption_loop_tramp/0)}.

crash_consumption_loop_tramp() ->
    misc:delaying_crash(1000, fun crash_consumption_loop/0).

crash_consumption_loop() ->
    {Name, Node, Status, Messages} = ns_crash_log:consume_oldest_message_from_inside_ns_server(),
    ?user_log(0,
              "Port server ~p on node ~p exited with status ~p. Restarting. "
              "Messages: ~s",
              [Name, Node, Status, Messages]),
    crash_consumption_loop().


log_filename() ->
    ns_config:search_node_prop(ns_config:get(), ns_log, filename).

maybe_upgrade_entry(#log_entry{} = X) ->
    X;
maybe_upgrade_entry({log_entry, _, _, _, _, _, _, _} = EntryV2_2_0) ->
    erlang:append_element(EntryV2_2_0, calendar:now_to_local_time(element(2, EntryV2_2_0))).

% will be added in R16
delete_element(Index, Tuple) ->
    L = tuple_to_list(Tuple),
    {F,[_|B]} = lists:split(Index - 1, L),
    list_to_tuple(F ++ B).

downgrade_entry(Entry) ->
    delete_element(#log_entry.server_time, Entry).

downgrade_entries(Entries) ->
    lists:map(fun downgrade_entry/1, Entries).

upgrade_entries(Entries) ->
    lists:map(fun maybe_upgrade_entry/1, Entries).

upgrade_entries_test() ->
    Now = now(),
    ServerTime = calendar:now_to_local_time(Now),
    Entries = [#log_entry{tstamp=Now, node=n1},
               {log_entry, Now, n2, a, a, a, a, a}],
    [A | [B | []]] = upgrade_entries(Entries),
    #log_entry{tstamp=Now, node=n1} = A,
    #log_entry{tstamp=Now, node=n2, server_time=ServerTime} = B,

    ok = try upgrade_entries([{log_entry, Now, n2, a, a, a}]) of
             X ->
                 X
         catch error:_ ->
                 ok
         end.

read_logs(Filename) ->
    case file:read_file(Filename) of
        {ok, <<>>} -> [];
        {ok, B} ->
            try upgrade_entries(binary_to_term(zlib:uncompress(B))) of
                B2 ->
                    B2
            catch error:Error ->
                    ?log_error("Couldn't load logs from ~p. Apparently ns_logs file is corrupted: ~p",
                               [Filename, Error]),
                    []
            end;
        E ->
            ?log_warning("Couldn't load logs from ~p (perhaps it's first startup): ~p", [Filename, E]),
            []
    end.

init([]) ->
    timer2:send_interval(?GC_TIME, garbage_collect),
    Filename = log_filename(),
    Recent = read_logs(Filename),
    %% initiate log syncing
    self() ! sync,
    erlang:process_flag(trap_exit, true),
    {ok, #state{unique_recent=Recent,
                dedup=dict:new(),
                filename=Filename}}.

delete_log() ->
    file:delete(log_filename()).

tail_of_length(List, N) ->
    case length(List) - N of
        X when X > 0 ->
            lists:nthtail(X, List);
        _ ->
            List
    end.

order_entries(A = #log_entry{}, B = #log_entry{}) ->
    A#log_entry{server_time = undefined} =< B#log_entry{server_time = undefined}.

flush_pending(#state{pending_recent = []} = State) ->
    State;
flush_pending(#state{unique_recent = Recent,
                     pending_recent = Pending} = State) ->
    NewRecent = tail_of_length(lists:umerge(fun order_entries/2, lists:sort(fun order_entries/2, Pending),
                                            Recent), ?RB_SIZE),
    State#state{unique_recent = NewRecent,
                pending_recent = [],
                pending_length = 0}.

add_pending(#state{pending_length = Length,
                   pending_recent = Pending} = State, Entry) ->
    NewState = State#state{pending_recent = [Entry | Pending],
                           pending_length = Length+1},
    case Length >= ?RB_SIZE of
        true ->
            flush_pending(NewState);
        _ -> NewState
    end.

%% Request for recent items.
handle_call(recent, _From, StateBefore) ->
    State = flush_pending(StateBefore),
    {reply, State#state.unique_recent, State, hibernate}.

%% Inbound logging request.
handle_cast({log, Module, Node, Time, Code, Category, Fmt, Args},
            State = #state{dedup=Dedup}) ->
    Key = {Module, Code, Category, Fmt, Args},
    case dict:find(Key, Dedup) of
        {ok, {Count, FirstSeen, LastSeen}} ->
            ?log_info("suppressing duplicate log ~p:~p(~p) because it's been "
                      "seen ~p times in the past ~p secs (last seen ~p secs ago",
                      [Module, Code, lists:flatten(io_lib:format(Fmt, Args)),
                       Count+1, timer:now_diff(Time, FirstSeen) / 1000000,
                       timer:now_diff(Time, LastSeen) / 1000000]),
            Dedup2 = dict:store(Key, {Count+1, FirstSeen, Time}, Dedup),
            {noreply, State#state{dedup=Dedup2}, hibernate};
        error ->
            Entry = #log_entry{node=Node, module=Module, code=Code, msg=Fmt,
                               args=Args, cat=Category, tstamp=Time},
            do_log(Entry),

            %% note that if message has undefined code it will be logged with
            %% 0 code (see do_log) but we still announce it here with actual
            %% undefined code for subscribers to know that the original
            %% message does not have a code attached to it; this will allow
            %% subscribers, for example, just ignore such messages if it's
            %% required by their context
            try gen_event:notify(ns_log_events, {ns_log, Category, Module, Code,
                                                 Fmt, Args})
            catch _:Reason ->
                    ?log_error("unable to notify listeners because of ~p",
                               [Reason])
            end,
            Dedup2 = dict:store(Key, {0, Time, Time}, Dedup),
            {noreply, State#state{dedup=Dedup2}, hibernate}
    end;
handle_cast({do_log, Entry}, State) ->
    {noreply, schedule_save(add_pending(State, maybe_upgrade_entry(Entry))), hibernate};
handle_cast({sync, SrcNode, Compressed}, StateBefore) ->
    State = flush_pending(StateBefore),
    Recent = State#state.unique_recent,
    case binary_to_term(zlib:uncompress(Compressed)) of
        Recent ->
            {noreply, State, hibernate};
        Logs ->
            State1 = schedule_save(State),
            UpgradedLogs = upgrade_entries(Logs),
            NewRecent = tail_of_length(lists:umerge(fun order_entries/2, Recent, UpgradedLogs),
                                       ?RB_SIZE),
            case NewRecent =/= UpgradedLogs of
                %% send back sync with fake src node. To avoid
                %% infinite sync exchange just in case.
                true -> send_sync_to(NewRecent, SrcNode, SrcNode);
                _ -> nothing
            end,
            {noreply, State1#state{unique_recent=NewRecent}, hibernate}
    end;
handle_cast(_, State) ->
    {noreply, State, hibernate}.

send_sync_to(Recent, Node) ->
    send_sync_to(Recent, Node, node()).

send_sync_to(Recent, Node, Src) ->
    Entries = case cluster_compat_mode:is_node_compatible(Node, [3,0,0]) of
                  true ->
                      Recent;
                  false ->
                      downgrade_entries(Recent)
              end,
    gen_server:cast({?MODULE, Node}, {sync, Src, zlib:compress(term_to_binary(Entries))}).

%% Not handling any other state.

%% Nothing special.
handle_info(garbage_collect, State) ->
    misc:flush(garbage_collect),
    {noreply, gc(State), hibernate};
handle_info(sync, StateBefore) ->
    State = flush_pending(StateBefore),
    Recent = State#state.unique_recent,
    erlang:send_after(5000 + random:uniform(55000), self(), sync),
    case nodes() of
        [] -> ok;
        Nodes ->
            Node = lists:nth(random:uniform(length(Nodes)), Nodes),
            send_sync_to(Recent, Node)
    end,
    {noreply, State, hibernate};
handle_info(save, StateBefore = #state{filename=Filename}) ->
    State = flush_pending(StateBefore),
    Recent = State#state.unique_recent,
    Compressed = zlib:compress(term_to_binary(Recent)),
    case file:write_file(Filename, Compressed) of
        ok -> ok;
        E ->
            ?log_error("unable to write log to ~p: ~p", [Filename, E])
    end,
    {noreply, State#state{save_tref=undefined}, hibernate};
handle_info(_Info, State) ->
    {noreply, State, hibernate}.

terminate(shutdown, State) ->
    handle_info(save, State);
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
            {Module, Code, Category, Fmt, Args} = Key,
            case Count of
                0 -> ok;
                _ ->
                    Entry = #log_entry{node=node(), module=Module,
                                       code=Code,
                                       msg=Fmt ++ " (repeated ~p times)",
                                       args=Args ++ [Count],
                                       cat=Category,

                                       tstamp=Now},
                    do_log(Entry)
            end,
            gc(Now, Rest, DupesList);
        false -> gc(Now, Rest, [{Key, Value} | DupesList])
    end.

schedule_save(State = #state{save_tref=undefined}) ->
    {ok, TRef} = timer2:send_after(?SAVE_DELAY, save),
    State#state{save_tref=TRef};
schedule_save(State) ->
    %% Don't reschedule if a save is already scheduled.
    State.

do_log(#log_entry{code=undefined} = Entry) ->
    %% Code can be undefined if logging module doesn't define ns_log_cat
    %% function. We change the code to 0 for such cases. Note that it must be
    %% done before abcast-ing (not in handle_cast) because some of the nodes
    %% in the cluster can be of the older version (thus this case won't be
    %% handled there).
    do_log(Entry#log_entry{code=0});
do_log(#log_entry{code=Code, tstamp=TStamp} = Entry) when is_integer(Code) ->
    EntryNew = Entry#log_entry{server_time=calendar:now_to_local_time(TStamp)},

    {NewNodes, OldNodes} = cluster_compat_mode:split_live_nodes_by_version([3, 0, 0]),
    gen_server:abcast(NewNodes, ?MODULE, {do_log, EntryNew}),

    case OldNodes of
        [] ->
            ok;
        _ ->
            EntryOld = downgrade_entry(EntryNew),
            gen_server:abcast(OldNodes, ?MODULE, {do_log, EntryOld})
    end.

%% API

-spec code_string(atom(), integer()) -> string().
code_string(Module, Code) ->
    case catch(Module:ns_log_code_string(Code)) of
        S when is_list(S) -> S;
        _                 -> "message"
    end.

-spec log(atom(), node(), Time, log_classification(), iolist(), list()) -> ok
       when Time :: {integer(), integer(), integer()}.
log(Module, Node, Time, Category, Fmt, Args) ->
    log(Module, Node, Time, undefined, Category, Fmt, Args).

%% A Code is an number which is module-specific.
-spec log(atom(), node(), Time,
          Code, log_classification(), iolist(), list()) -> ok
      when Time :: {integer(), integer(), integer()},
           Code :: integer() | undefined.
log(Module, Node, Time, Code, Category, Fmt, Args) ->
    gen_server:cast(?MODULE,
                    {log, Module, Node, Time, Code, Category, Fmt, Args}).

-spec recent() -> list(#log_entry{}).
recent() ->
    gen_server:call(?MODULE, recent).

-spec recent(atom()) -> list(#log_entry{}).
recent(Module) ->
    [E || E <- gen_server:call(?MODULE, recent),
          E#log_entry.module =:= Module ].

%% Example categorization -- pretty much exists for the test below, but
%% this is what any module that logs should look like.
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

%% ------------------------------------------

%% TODO make this work
-ifdef(nothing).

log_test() ->
    ok = log(?MODULE, 1, "not ready log"),

    {ok, Pid} = gen_server:start(?MODULE, [], []),
    ok = log(?MODULE, 1, "test log 1"),
    ok = log(?MODULE, 2, "test log 2 ~p ~p", [x, y]),
    ok = log(?MODULE, 3, "test log 3 ~p ~p", [x, y]),
    ok = log(?MODULE, 4, "test log 4 ~p ~p", [x, y]),

    exit(Pid, exiting),
    ok.
-endif.
