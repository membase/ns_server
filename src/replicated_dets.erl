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

-export([start_link/6, set/3, delete/2, get/2, get/3, select/3, empty/1]).

-export([init/1, init_after_ack/1, handle_call/3, handle_info/2,
         get_id/1, find_doc/2, get_all_docs/1,
         get_revision/1, set_revision/2, is_deleted/1, save_doc/2]).

-record(state, {child_module :: atom(),
                child_state :: term(),
                path :: string(),
                name :: atom()}).

-record(doc, {id :: term(),
              rev :: term(),
              deleted :: boolean(),
              value :: term()}).

start_link(ChildModule, InitParams, Name, Path, Replicator, CacheSize) ->
    replicated_storage:start_link(Name, ?MODULE,
                                  [Name, ChildModule, InitParams, Path, Replicator, CacheSize],
                                  Replicator).

set(Name, Id, Value) ->
    gen_server:call(Name, {interactive_update, #doc{id = Id,
                                                    rev = 0,
                                                    deleted = false,
                                                    value = Value}}, infinity).

delete(Name, Id) ->
    gen_server:call(Name, {interactive_update, #doc{id = Id,
                                                    rev = 0,
                                                    deleted = true,
                                                    value = []}}, infinity).

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
    DocSpec = #doc{id = KeySpec, deleted = false, _ = '_'},
    MatchSpec = [{DocSpec, [], ['$_']}],
    ?make_producer(select_from_dets(Name, MatchSpec, N, ?yield())).

init([Name, ChildModule, InitParams, Path, Replicator, CacheSize]) ->
    replicated_storage:anounce_startup(Replicator),
    ChildState = ChildModule:init(InitParams),
    mru_cache:new(Name, CacheSize),
    #state{name = Name,
           path = Path,
           child_module = ChildModule,
           child_state = ChildState}.

init_after_ack(State) ->
    ok = open(State),
    State.

open(#state{path = Path, name = TableName}) ->
    {ok, TableName} =
        dets:open_file(TableName,
                       [{type, set},
                        {auto_save, ns_config:read_key_fast(replicated_dets_auto_save, 60000)},
                        {keypos, #doc.id},
                        {file, Path}]),
    ok.

get_id(#doc{id = Id}) ->
    Id.

find_doc(Id, #state{name = TableName}) ->
    case dets:lookup(TableName, Id) of
        [Doc] ->
            Doc;
        [] ->
            false
    end.

get_all_docs(#state{name = TableName}) ->
    %% TODO to be replaced with something that does not read the whole thing to memory
    dets:foldl(fun(Doc, Acc) ->
                       [Doc | Acc]
               end, [], TableName).

get_revision(#doc{rev = Rev}) ->
    Rev.

set_revision(Doc, NewRev) ->
    Doc#doc{rev = NewRev}.

is_deleted(#doc{deleted = Deleted}) ->
    Deleted.

save_doc(#doc{id = Id,
              deleted = Deleted,
              value = Value} = Doc,
         #state{name = TableName,
                child_module = ChildModule,
                child_state = ChildState} = State) ->
    ok = dets:insert(TableName, [Doc]),
    NewChildState = ChildModule:on_save(Id, ChildState),
    case Deleted of
        true ->
            _ = mru_cache:delete(TableName, Id);
        false ->
            _ = mru_cache:update(TableName, Id, Value)
    end,
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
                                 child_state = ChildState} = State) ->
    ok = dets:delete_all_objects(TableName),
    NewChildState = ChildModule:on_empty(ChildState),
    mru_cache:flush(TableName),
    {reply, ok, State#state{child_state = NewChildState}}.

handle_info({cache, Id} = Msg, #state{name = TableName} = State) ->
    case dets:lookup(TableName, Id) of
        [#doc{id = Id, deleted = false, value = Value}] ->
            _ = mru_cache:add(TableName, Id, Value);
        _ ->
            ok
    end,
    misc:flush(Msg),
    {noreply, State}.

select_from_dets(Name, MatchSpec, N, Yield) ->
    {ok, TableName} = gen_server:call(Name, suspend, infinity),
    dets:safe_fixtable(TableName, true),
    do_select_from_dets(TableName, MatchSpec, N, Yield),
    dets:safe_fixtable(Name, false),
    Name ! release,
    ok.

do_select_from_dets(TableName, MatchSpec, N, Yield) ->
    case dets:select(TableName, MatchSpec, N) of
        {Selection, Continuation} when is_list(Selection) ->
            do_select_from_dets_continue(Selection, Continuation, Yield);
        '$end_of_table' ->
            ok
    end.

do_select_from_dets_continue(Selection, Continuation, Yield) ->
    lists:foreach(fun (#doc{id = Id, value = Value}) ->
                          Yield({Id, Value})
                  end, Selection),
    case dets:select(Continuation) of
        {Selection2, Continuation2} when is_list(Selection2) ->
            do_select_from_dets_continue(Selection2, Continuation2, Yield);
        '$end_of_table' ->
            ok
    end.
