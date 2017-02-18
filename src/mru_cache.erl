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
