%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
%% @doc replicated storage based on dets

-module(replicated_dets).

-include("ns_common.hrl").
-include("pipes.hrl").

-behaviour(replicated_storage).

-export([start_link/6, set/3, delete/2, delete_all/1, get/2, get/3, select/3, select/4, empty/1,
         select_with_update/4]).

-export([init/1, init_after_ack/1, handle_call/3, handle_info/2,
         get_id/1, get_value/1, find_doc/2, find_doc_rev/2, all_docs/1,
         get_revision/1, set_revision/2, is_deleted/1, save_docs/2, handle_mass_update/3]).

-record(state, {child_module :: atom(),
                child_state :: term(),
                path :: string(),
                name :: atom(),
                revisions :: term()}).

-record(doc, {id :: term(),
              rev :: term(),
              deleted :: boolean(),
              value :: term()}).

start_link(ChildModule, InitParams, Name, Path, Replicator, CacheSize) ->
    replicated_storage:start_link(Name, ?MODULE,
                                  [Name, ChildModule, InitParams, Path, Replicator, CacheSize],
                                  Replicator).

set(Name, Id, Value) ->
    gen_server:call(Name, {interactive_update, update_doc(Id, Value)}, infinity).

delete(Name, Id) ->
    gen_server:call(Name, {interactive_update, delete_doc(Id)}, infinity).

delete_doc(Id) ->
    #doc{id = Id, rev = 0, deleted = true, value = []}.

update_doc(Id, Value) ->
    #doc{id = Id, rev = 0, deleted = false, value = Value}.

delete_all(Name) ->
    Keys =
        pipes:run(select(Name, '_', 100),
                  ?make_consumer(
                     pipes:fold(?producer(),
                                fun ({Key, _}, Acc) ->
                                        [Key | Acc]
                                end, []))),
    lists:foreach(fun (Key) ->
                          delete(Name, Key)
                  end, Keys).

empty(Name) ->
    gen_server:call(Name, empty, infinity).

get(TableName, Id) ->
    case mru_cache:lookup(TableName, Id) of
        {ok, V} ->
            {Id, V};
        false ->
            case dets:lookup(TableName, Id) of
                [#doc{id = Id, deleted = false, value = Value}] ->
                    TableName ! {cache, Id},
                    {Id, Value};
                [#doc{id = Id, deleted = true}] ->
                    false;
                [] ->
                    false
            end
    end.

get(Name, Id, Default) ->
    case get(Name, Id) of
        false ->
            Default;
        {Id, Value} ->
            Value
    end.

select(Name, KeySpec, N) ->
    select(Name, KeySpec, N, false).

select(Name, KeySpec, N, Locked) ->
    DocSpec = #doc{id = KeySpec, deleted = false, _ = '_'},
    MatchSpec = [{DocSpec, [], ['$_']}],

    Select =
        case Locked of
            true ->
                fun select_from_dets_locked/4;
            false ->
                fun select_from_dets/4
        end,

    ?make_producer(Select(Name, MatchSpec, N,
                          fun (Selection) ->
                                  lists:foreach(fun (#doc{id = Id, value = Value}) ->
                                                        ?yield({Id, Value})
                                                end, Selection)
                          end)).

select_with_update(Name, KeySpec, N, UpdateFun) ->
    gen_server:call(Name, {mass_update, {Name, KeySpec, N, UpdateFun}}, infinity).

handle_mass_update({Name, KeySpec, N, UpdateFun}, Updater, _State) ->
    Transducer =
        ?make_transducer(
           pipes:foreach(
             ?producer(),
             fun ({Id, Value}) ->
                     case UpdateFun(Id, Value) of
                         skip ->
                             ok;
                         delete ->
                             ?yield(delete_doc(Id));
                         {update, NewValue} ->
                             ?yield(update_doc(Id, NewValue))
                     end
             end)),
    {RawErrors, ParentState} = pipes:run(select(Name, KeySpec, N, true), Transducer, Updater),
    Errors = [{Id, Error} || {#doc{id = Id}, Error} <- RawErrors],
    {Errors, ParentState}.

init([Name, ChildModule, InitParams, Path, Replicator, CacheSize]) ->
    replicated_storage:anounce_startup(Replicator),
    ChildState = ChildModule:init(InitParams),
    mru_cache:new(Name, CacheSize),
    #state{name = Name,
           path = Path,
           child_module = ChildModule,
           child_state = ChildState}.

init_after_ack(State = #state{name = TableName}) ->
    ok = open(State),
    Revisions = ets:new(ok, [set, private]),
    MatchSpec = [{#doc{id = '$1', rev = '$2', _ = '_'}, [], [{{'$1', '$2'}}]}],

    Start = os:timestamp(),
    select_from_dets_locked(TableName, MatchSpec, 100,
                            fun (Selection) ->
                                    ets:insert_new(Revisions, Selection)
                            end),
    ?log_debug("Loading ~p items, ~p words took ~pms",
               [ets:info(Revisions, size),
                ets:info(Revisions, memory),
                timer:now_diff(os:timestamp(), Start) div 1000]),

    State#state{revisions = Revisions}.

open(#state{path = Path, name = TableName}) ->
    ?log_debug("Opening file ~p", [Path]),
    case do_open(Path, TableName, 3) of
        ok ->
            ok;
        error ->
            {A, B, C} = erlang:now(),
            Backup = lists:flatten(
                       io_lib:format(
                         "~s.~4..0b-~6..0b-~6..0b.bak", [Path, A, B, C])),
            ?log_error("Renaming possibly corrupted dets file ~p to ~p", [Path, Backup]),
            ok = file:rename(Path, Backup),
            ok = do_open(Path, TableName, 1)
    end.

do_open(_Path, _TableName, 0) ->
    error;
do_open(Path, TableName, Tries) ->
    case dets:open_file(TableName,
                        [{type, set},
                         {auto_save, ns_config:read_key_fast(replicated_dets_auto_save, 60000)},
                         {keypos, #doc.id},
                         {file, Path}]) of
        {ok, TableName} ->
            ok;
        Error ->
            ?log_error("Unable to open ~p, Error: ~p", [Path, Error]),
            timer:sleep(1000),
            do_open(Path, TableName, Tries - 1)
    end.

get_id(#doc{id = Id}) ->
    Id.

get_value(#doc{value = Value}) ->
    Value.

find_doc(Id, #state{name = TableName}) ->
    case dets:lookup(TableName, Id) of
        [Doc] ->
            Doc;
        [] ->
            false
    end.

find_doc_rev(Id, #state{revisions = Revisions}) ->
    case ets:lookup(Revisions, Id) of
        [{Id, Rev}] ->
            Rev;
        [] ->
            false
    end.

all_docs(Pid) ->
    ?make_producer(select_from_dets(Pid, [{'_', [], ['$_']}], 500,
                                    fun (Batch) -> ?yield({batch, Batch}) end)).

get_revision(#doc{rev = Rev}) ->
    Rev.

set_revision(Doc, NewRev) ->
    Doc#doc{rev = NewRev}.

is_deleted(#doc{deleted = Deleted}) ->
    Deleted.

save_docs(Docs, #state{name = TableName,
                       child_module = ChildModule,
                       child_state = ChildState,
                       revisions = Revisions} = State) ->
    ok = dets:insert(TableName, Docs),
    true = ets:insert(Revisions, [{Doc#doc.id, Doc#doc.rev} || Doc <- Docs]),
    lists:foreach(fun (#doc{id = Id, deleted = true}) ->
                          _ = mru_cache:delete(TableName, Id);
                      (#doc{id = Id, deleted = false, value = Value}) ->
                          _ = mru_cache:update(TableName, Id, Value)
                  end, Docs),
    NewChildState = ChildModule:on_save(Docs, ChildState),
    {ok, State#state{child_state = NewChildState}}.

handle_call(suspend, {Pid, _} = From, #state{name = TableName} = State) ->
    MRef = erlang:monitor(process, Pid),
    ?log_debug("Suspended by process ~p", [Pid]),
    gen_server:reply(From, {ok, TableName}),
    receive
        {'DOWN', MRef, _, _, _} ->
            ?log_info("Suspending process ~p died", [Pid]),
            {noreply, State};
        release ->
            ?log_debug("Released by process ~p", [Pid]),
            erlang:demonitor(MRef, [flush]),
            {noreply, State}
    end;
handle_call(empty, _From, #state{name = TableName,
                                 child_module = ChildModule,
                                 child_state = ChildState,
                                 revisions = Revisions} = State) ->
    ok = dets:delete_all_objects(TableName),
    true = ets:delete_all_objects(Revisions),
    mru_cache:flush(TableName),
    NewChildState = ChildModule:on_empty(ChildState),
    {reply, ok, State#state{child_state = NewChildState}};
handle_call(Msg, From, #state{name = TableName,
                              child_module = ChildModule,
                              child_state = ChildState} = State) ->
    {reply, RV, NewChildState} = ChildModule:handle_call(Msg, From, TableName, ChildState),
    {reply, RV, State#state{child_state = NewChildState}}.

handle_info({cache, Id} = Msg, #state{name = TableName} = State) ->
    case dets:lookup(TableName, Id) of
        [#doc{id = Id, deleted = false, value = Value}] ->
            _ = mru_cache:add(TableName, Id, Value);
        _ ->
            ok
    end,
    misc:flush(Msg),
    {noreply, State};
handle_info(Msg, #state{child_module = ChildModule,
                        child_state = ChildState} = State) ->
    {noreply, NewChildState} = ChildModule:handle_info(Msg, ChildState),
    {noreply, State#state{child_state = NewChildState}}.

select_from_dets(Name, MatchSpec, N, Yield) ->
    {ok, TableName} = gen_server:call(Name, suspend, infinity),
    RV = select_from_dets_locked(TableName, MatchSpec, N, Yield),
    Name ! release,
    RV.

select_from_dets_locked(TableName, MatchSpec, N, Yield) ->
    ?log_debug("Starting select with ~p", [{TableName, MatchSpec, N}]),
    dets:safe_fixtable(TableName, true),
    do_select_from_dets(TableName, MatchSpec, N, Yield),
    dets:safe_fixtable(TableName, false),
    ok.

do_select_from_dets(TableName, MatchSpec, N, Yield) ->
    case dets:select(TableName, MatchSpec, N) of
        {Selection, Continuation} when is_list(Selection) ->
            do_select_from_dets_continue(Selection, Continuation, Yield);
        '$end_of_table' ->
            ok
    end.

do_select_from_dets_continue(Selection, Continuation, Yield) ->
    Yield(Selection),
    case dets:select(Continuation) of
        {Selection2, Continuation2} when is_list(Selection2) ->
            do_select_from_dets_continue(Selection2, Continuation2, Yield);
        '$end_of_table' ->
            ok
    end.
