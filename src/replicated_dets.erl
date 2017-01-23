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

-behaviour(replicated_storage).

-export([start_link/3, set/3, delete/2, get/2]).

-export([init/1, init_after_ack/1, handle_call/3,
         get_id/1, find_doc/2, get_all_docs/1,
         get_revision/1, set_revision/2, is_deleted/1, save_doc/2]).

-record(state, {path :: string(),
                name :: string()}).

-record(doc, {id :: term(),
              rev :: term(),
              deleted :: boolean(),
              value :: term()}).

start_link(Name, Path, Replicator) ->
    replicated_storage:start_link(Name, ?MODULE, [Name, Path, Replicator], Replicator).

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

get(Name, Id) ->
    gen_server:call(Name, {get, Id}, infinity).

init([Name, Path, Replicator]) ->
    replicated_storage:anounce_startup(Replicator),
    #state{name = Name,
           path = Path}.

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

save_doc(Doc, #state{name = TableName} = State) ->
    ok = dets:insert(TableName, [Doc]),
    {ok, State}.

handle_call({get, Id}, _From, #state{name = TableName} = State) ->
    RV = case dets:lookup(TableName, Id) of
             [#doc{id = Id, deleted = false, value = Value}] ->
                 {Id, Value};
             [#doc{id = Id, deleted = true}] ->
                 false;
             [] ->
                 false
         end,
    {reply, RV, State}.
