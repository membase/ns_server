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

-module(mru_cache).

-include("triq.hrl").

-export([new/2, dispose/1,
         lookup/2, add/3, update/3, delete/2,
         flush/1]).

new(Name, Size) ->
    ets:new(Name, [named_table, set, public]),
    Recent = ets:new(ok, [set, public]),
    Stale = ets:new(ok, [set, public]),

    true = ets:insert_new(Name, {max_size, Size}),
    true = ets:insert_new(Name, {tables, {Recent, Stale}}).

dispose(Name) ->
    {Recent, Stale} = get_tables(Name),
    ets:delete(Recent),
    ets:delete(Stale),
    ets:delete(Name).

lookup(Name, Key) ->
    with_item_lock(
      Name, Key,
      fun () ->
              {Recent, Stale} = get_tables(Name),
              do_lookup(Name, Recent, Stale, Key)
      end).

do_lookup(Name, Recent, Stale, Key) ->
    case get_one(Recent, Key) of
        false ->
            case get_one(Stale, Key) of
                false ->
                    false;
                {ok, Value} ->
                    %% the key might have been evicted (or entire cache might
                    %% have been flushed) while we waited on the lock; so we
                    %% need to be prepared
                    case migrate(Name, Recent, Stale, {Key, Value}) of
                        ok ->
                            {ok, Value};
                        not_found ->
                            false
                    end
            end;
        {ok, Value} ->
            {ok, Value}
    end.

update(Name, Key, Value) ->
    with_item_lock(
      Name, Key,
      fun () ->
              {Recent, Stale} = get_tables(Name),
              do_update(Recent, Stale, Key, Value)
      end).

do_update(Recent, Stale, Key, Value) ->
    case update_item(Recent, Key, Value) of
        true ->
            ok;
        false ->
            case update_item(Stale, Key, Value) of
                true ->
                    ok;
                false ->
                    not_found
            end
    end.

add(Name, Key, Value) ->
    with_item_lock(
      Name, Key,
      fun () ->
              {Recent, Stale} = get_tables(Name),
              do_add(Name, Recent, Stale, Key, Value)
      end).

do_add_try_update(Name, Recent, Stale, Key, Value) ->
    case update_item(Recent, Key, Value) of
        true ->
            ok;
        false ->
            migrate(Name, Recent, Stale, {Key, Value})
    end.

do_add(Name, Recent, Stale, Key, Value) ->
    case do_add_try_update(Name, Recent, Stale, Key, Value) of
        ok ->
            false;
        not_found ->
            add_recent(Name, {Key, Value}),
            true
    end.

delete(Name, Key) ->
    with_item_lock(
      Name, Key,
      fun () ->
              {Recent, Stale} = get_tables(Name),
              case ets:member(Recent, Key) orelse ets:member(Stale, Key) of
                  true ->
                      do_delete(Name, Recent, Stale, Key),
                      ok;
                  false ->
                      not_found
              end
      end).

do_delete(Name, Recent, Stale, Key) ->
    with_lock(
      Name, housekeeping,
      fun () ->
              ets:delete(Recent, Key),
              ets:delete(Stale, Key)
      end).

flush(Name) ->
    with_lock(
      Name, housekeeping,
      fun () ->
              %% it's safe to just delete all objects from both recent and
              %% stale tables; the concurrent operations might end up looking
              %% as if they happened before or after the flush; so we just
              %% need to ensure that migrate, add_recent and do_delete do not
              %% violate any invariants; migrate is prepared that item of
              %% interest might have been evicted/flushed, do_delete just
              %% blindly deletes the object from both tables, add_recent will
              %% just insert a new item into the recent table
              {Recent, Stale} = get_tables(Name),
              ets:delete_all_objects(Recent),
              ets:delete_all_objects(Stale),
              ok
      end).

%% internal
get_tables(Name) ->
    {ok, Tables} = get_one(Name, tables),
    Tables.

migrate(Name, Recent, Stale, {Key, _} = Item) ->
    with_lock(
      Name, housekeeping,
      fun () ->
              %% the "recent" and "stale" tables might have been swapped; but
              %% since this only happens when stale table is empty and we hold
              %% the lock for our own key, ets:member will always return false
              %% in such case, so we are safe here
              case ets:member(Stale, Key) of
                  true ->
                      %% just asserting that tables weren't swapped
                      {Recent, Stale} = get_tables(Name),

                      ets:delete(Stale, Key),
                      true = ets:insert_new(Recent, Item),
                      maybe_swap_tables(Name, Recent, Stale, Item),
                      ok;
                  false ->
                      not_found
              end
      end).

add_recent(Name, Item) ->
    with_lock(
      Name, housekeeping,
      fun () ->
              %% the "recent" and "swapped" tables might have been swapped
              %% while we were waiting for the housekeeping lock, so we cannot
              %% just use the values passed from our caller; but given we have
              %% proper tables, the logic doesn't change otherwise: since
              %% we're adding a new element, it must not have existed in any
              %% of the tables
              {Recent, Stale} = get_tables(Name),
              true = ets:insert_new(Recent, Item),

              maybe_evict(Name, Recent, Stale),
              maybe_swap_tables(Name, Recent, Stale, Item)
      end).

maybe_evict(Name, Recent, Stale) ->
    {ok, MaxSize} = get_one(Name, max_size),
    RecentSize = ets:info(Recent, size),
    StaleSize = ets:info(Stale, size),
    case RecentSize + StaleSize > MaxSize of
        true ->
            %% one of our invariants is that when we need to evict, there's at
            %% least one item in the stale table
            true = (StaleSize >= 1),
            evict(Stale);
        false ->
            ok
    end.

evict(Stale) ->
    Victim = ets:first(Stale),
    %% we are holding the housekeeping lock, so the item couldn't have been
    %% deleted or migrated
    ets:delete(Stale, Victim).

maybe_swap_tables(Name, Recent, Stale, LastItem) ->
    {ok, MaxSize} = get_one(Name, max_size),
    RecentSize = ets:info(Recent, size),

    case RecentSize =:= MaxSize of
        true ->
            true = (ets:info(Stale, size) =:= 0),
            swap_tables(Name, Recent, Stale, LastItem);
        false ->
            ok
    end.

swap_tables(Name, Recent, Stale, {Key, _} = LastItem) ->
    NewRecent = Stale,
    NewStale = Recent,

    %% we leave just the most recent item in the new recent table; in addition
    %% we need to delete it from what used to be recent
    ets:delete(NewStale, Key),
    true = ets:insert_new(NewRecent, LastItem),

    %% now actual swapping
    update_item(Name, tables, {NewRecent, NewStale}).

%% locking stuff
take_lock(Name, Lock) ->
    case ets:insert_new(Name, {Lock, {}}) of
        true ->
            ok;
        false ->
            erlang:yield(),
            take_lock(Name, Lock)
    end.

put_lock(Name, Lock) ->
    ets:delete(Name, Lock).

with_item_lock(Name, Key, Body) ->
    with_lock(Name, {lock, Key}, Body).

with_lock(Name, Lock, Body) ->
    take_lock(Name, Lock),
    try
        Body()
    after
        put_lock(Name, Lock)
    end.

%% ets helpers
get_one(Table, Key) ->
    case ets:lookup(Table, Key) of
        [] ->
            false;
        [{Key, Value}] ->
            {ok, Value}
    end.

update_item(Table, Key, Value) ->
    ets:update_element(Table, Key, {2, Value}).

%% triq stuff
-define(CACHE, test_cache).
-define(CACHE_SIZE, 8).
-define(KEYS, [list_to_atom([C]) || C <- lists:seq($a, $a + 2 * ?CACHE_SIZE)]).

%% generators for the cache operation
key() ->
    oneof(?KEYS).

value() ->
    int().

ops() ->
    list(op()).

op() ->
    frequency([{1, op_flush()},
               {20, ?LET(Key, key(),
                         frequency([{3, op_lookup(Key)},
                                    {2, op_add(Key)},
                                    {2, op_update(Key)},
                                    {2, op_delete(Key)}]))}]).

op_lookup(Key) ->
    {lookup, Key}.

op_add(Key) ->
    {add, Key, value()}.

op_update(Key) ->
    {update, Key, value()}.

op_delete(Key) ->
    {delete, Key}.

op_flush() ->
    flush.

%% routines to run and validate operations on cache
-record(cache_state, {meta, items, stale_count, recent_count}).

get_cache_state() ->
    {Recent, Stale} = get_tables(?CACHE),
    Items = lists:sort([{K, {recent, V}} || {K, V} <- ets:tab2list(Recent)] ++
                           [{K, {stale, V}} || {K, V} <- ets:tab2list(Stale)]),
    RecentCount = ets:info(Recent, size),
    StaleCount = ets:info(Stale, size),
    #cache_state{meta = ets:tab2list(?CACHE),
                 items = Items,
                 recent_count = RecentCount,
                 stale_count = StaleCount}.

dispatch_op(Op) when is_atom(Op) ->
    dispatch_op({Op});
dispatch_op(Op) when is_tuple(Op) ->
    [F | Args] = tuple_to_list(Op),
    R = erlang:apply(mru_cache, F, [?CACHE | Args]),
    {R, get_cache_state()}.

run_check_cache(Operations, Check) ->
    run_check_cache(Operations,
                    fun (Op, Result, State) ->
                            case Check(Op, Result) of
                                ok ->
                                    {ok, State};
                                Other ->
                                    Other
                            end
                    end, ignored).

run_check_cache(Operations, Check, InitState) ->
    mru_cache:new(?CACHE, ?CACHE_SIZE),
    try
        check_cache_loop(Operations, [], Check, InitState)
    after
        mru_cache:dispose(?CACHE)
    end.

check_cache_loop([], _, _, _) ->
    true;
check_cache_loop([Op | Ops], Trace, Check, State) ->
    NewTrace = [Op | Trace],

    try dispatch_op(Op) of
        Result ->
            case Check(Op, Result, State) of
                {ok, NewState} ->
                    check_cache_loop(Ops, [Op | Trace], Check, NewState);
                {failed, Diag} ->
                    {failed, [{ops, lists:reverse(NewTrace)} | Diag]}
            end
    catch
        T:E ->
            Stack = erlang:get_stacktrace(),
            {raised, [{what, {T, E}},
                      {stack, Stack},
                      {ops, lists:reverse(NewTrace)},
                      {last_state, State},
                      {cache_state, get_cache_state()}]}
    end.

check_invariants(Operations) ->
    run_check_cache(
      Operations,
      fun (_, {_, State}) ->
              #cache_state{meta = Meta,
                           recent_count = Recent,
                           stale_count = Stale,
                           items = Items} = State,
              Invariants =
                  [{meta, (proplists:get_keys(Meta) --
                               [max_size, tables]) =:= []},
                   {max_size, Recent + Stale =< ?CACHE_SIZE},
                   {recent, Recent < ?CACHE_SIZE},
                   {no_dups, lists:sort(proplists:get_keys(Items)) =:=
                        lists:usort(proplists:get_keys(Items))}],

              Violated = [P || {_, false} = P <- Invariants],
              case Violated of
                  [] ->
                      ok;
                  _ ->
                      {failed, [{cache_state, State},
                                {violated_invariants, Violated}]}
              end
      end).

%% triq properties
prop_invariants_() ->
    {?FORALL(Ops, ops(), check_invariants(Ops) =:= true),
     [{iters, 1000},
      {diag, fun check_invariants/1}]}.
