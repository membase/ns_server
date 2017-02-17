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
%% @doc simple ets based lru cache

-module(lru_cache).

-behaviour(gen_server).

-export([start_link/2, lookup/2, add/3, update/3, delete/2, flush/1]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {ets,
                size :: integer(),
                evict_list :: list()
               }).

start_link(Name, Size) ->
    gen_server:start_link({local, Name}, ?MODULE, Size, []).

lookup(Name, Key) ->
    gen_server:call(Name, {lookup, Key}).

add(Name, Key, Value) ->
    gen_server:call(Name, {add, Key, Value}).

update(Name, Key, Value) ->
    gen_server:call(Name, {update, Key, Value}).

delete(Name, Key) ->
    gen_server:call(Name, {delete, Key}).

flush(Name) ->
    gen_server:call(Name, flush).

init(Size) ->
    {ok, #state{ets = ets:new(ok, []),
                size = Size,
                evict_list = []}}.

handle_call({lookup, Key}, _From, #state{ets = Ets} = State) ->
    case ets:lookup(Ets, Key) of
        [{Key, Value}] ->
            {reply, {ok, Value}, touch_key(Key, State)};
        [] ->
            {reply, false, State}
    end;
handle_call({add, Key, Value}, _From, #state{ets = Ets} = State) ->
    case ets:member(Ets, Key) of
        true ->
            ets:insert(Ets, {Key, Value}),
            {reply, false, touch_key(Key, State)};
        false ->
            ets:insert_new(Ets, {Key, Value}),
            {reply, true, add_key(Key, State)}
    end;
handle_call({update, Key, Value}, _From, #state{ets = Ets} = State) ->
    case ets:member(Ets, Key) of
        true ->
            ets:insert(Ets, {Key, Value}),
            {reply, ok, State};
        false ->
            {reply, not_found, State}
    end;
handle_call({delete, Key}, _From, #state{ets = Ets} = State) ->
    case ets:member(Ets, Key) of
        true ->
            ets:delete(Ets, Key),
            {reply, ok, remove_key(Key, State)};
        false ->
            {reply, not_found, State}
    end;
handle_call(flush, _From, #state{ets = Ets} = State) ->
    ets:delete_all_objects(Ets),
    {reply, ok, State#state{evict_list = []}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

touch_key(Key, #state{evict_list = [Key | _]} = State) ->
    State;
touch_key(Key, #state{evict_list = EvictList} = State) ->
    State#state{evict_list = [Key | lists:delete(Key, EvictList)]}.

remove_key(Key, #state{evict_list = EvictList} = State) ->
    State#state{evict_list = lists:delete(Key, EvictList)}.

add_key(Key, #state{ets = Ets,
                    size = Size,
                    evict_list = EvictList} = State) ->
    NewEvictList =
        case length(EvictList) of
            Size ->
                {Prev, [Last]} = lists:split(Size - 1, EvictList),
                ets:delete(Ets, Last),
                Prev;
            _ ->
                EvictList
        end,
    State#state{evict_list = [Key | NewEvictList]}.
