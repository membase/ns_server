%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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
%% Streaming json encoder and pretty printer. And maybe one day a parser too.
%%
%% The focus is not high performance, but more or less constant memory
%% profile. In addition, other json encoders for erlang (at least the once
%% that we use) do not provide pretty printing.
%%
-module(sjson).

-include("pipes.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("triq.hrl").

-export([stream_json/1,
         encode_json/0, encode_json/1,
         encode_extended_json/0, encode_extended_json/1]).

-export_type([json/0,
              json_number/0, json_array/0, json_object/0,
              json_string/0, json_boolean/0, json_null/0]).
-export_type([json_ext_event/0, json_event/0]).
-export_type([encoder_option/0, encoder_options/0]).

%% This just follows ejson representation of terms that can be encoded to json.
-type json() :: json_literal() | json_compound().

-type json_literal() :: json_number() |
                        json_string() |
                        json_boolean() |
                        json_null().
-type json_compound() :: json_array() |
                         json_object().

-type json_number() :: number().
-type json_array() :: [json()].
-type json_object() :: {[json_kv()]}.
-type json_kv() :: {json_string(), json()}.
-type json_string() :: binary() | atom().
-type json_boolean() :: boolean().
-type json_null() :: null.

-type json_ext_event() ::
        json_event() |
        %% for simplicity sake one might want to stream json objects
        %% without traversing them all the way
        {json, json()} |
        {kv, json_kv()}.

-type json_event() :: array_start | array_end |
                      object_start | object_end |
                      {kv_start, json_string()} | kv_end |
                      {literal, json_literal()}.

-type encoder_option() :: {compact, boolean()} |
                          {strict, boolean()} |
                          {indent, binary()}.

-type encoder_options() :: [encoder_option()].

-spec stream_json(json()) -> pipes:producer(json_event()).
stream_json(Json) ->
    ?make_producer(walk_json(?yield(), Json)).

-spec expand_extended_json() -> pipes:transducer(json_ext_event(), json_event()).
expand_extended_json() ->
    ?make_transducer(
       pipes:foreach(?producer(),
                     fun (Event) ->
                             case Event of
                                 {json, Json} ->
                                     walk_json(?yield(), Json);
                                 {kv, KV} ->
                                     walk_json_kv(?yield(), KV);
                                 _ ->
                                     ?yield(Event)
                             end
                     end)).

-spec encode_extended_json() -> pipes:transducer(json_ext_event(), iolist()).
encode_extended_json() ->
    encode_extended_json([]).

-spec encode_extended_json(encoder_options()) -> pipes:transducer(
                                                   json_ext_event(),
                                                   iolist()).
encode_extended_json(Options) ->
    ?make_transducer(
       begin
           Producer = pipes:compose(pipes:compose(?producer(),
                                                  expand_extended_json()),
                                    encode_json(Options)),
           pipes:foreach(Producer, ?yield())
       end).

-spec encode_json() -> pipes:transducer(json_event(), iolist()).
encode_json() ->
    encode_json([]).

-spec encode_json(encoder_options()) -> pipes:transducer(json_event(), iolist()).
encode_json(Options) ->
    ?make_transducer(
       begin
           State = pipes:fold(?producer(), fun encoder_loop/2,
                              init_encoder_state(?yield(), Options)),
           maybe_emit_final_newline(State)
       end).

%% internal
-record(encoder_state, {
          yield   :: pipes:yield(iolist()),
          strict  :: boolean(),
          compact :: boolean(),
          indent  :: binary(),

          last_event     :: start | array_start | object_start | kv_start | other,
          breadcrumb     :: [array | object | kv],
          nesting_level  :: non_neg_integer(),
          current_indent :: binary()
         }).

init_encoder_state(Yield, Options) ->
    Compact = proplists:get_value(compact, Options, true),
    Indent = proplists:get_value(indent, Options, <<"  ">>),
    Strict = proplists:get_value(strict, Options, true),

    #encoder_state{
       yield = Yield,
       compact = Compact,
       strict = Strict,
       indent = Indent,
       last_event = start,
       breadcrumb = [],
       nesting_level = 0,
       current_indent = <<>>}.

encoder_loop(Event, State) ->
    maybe_validate_event(Event, State),
    NewState = update_nesting(Event, State),

    Encoded = [maybe_add_separator(Event, NewState),
               maybe_prettify(Event, NewState),
               encode_event(Event)],
    emit(Encoded, NewState),

    NewState1 = update_last_event(Event, NewState),
    maybe_update_breadcrumb(Event, NewState1).

update_last_event(Event, #encoder_state{last_event = LastEvent} = State) ->
    EventType =
        case Event of
            array_start -> Event;
            object_start -> Event;
            {kv_start, _} -> kv_start;
            _ -> other
        end,

    case EventType =/= LastEvent of
        true ->
            State#encoder_state{last_event = EventType};
        false ->
            State
    end.

update_nesting(Event, #encoder_state{nesting_level = Level,
                                     last_event = LastEvent} = State) ->
    case do_update_nesting(LastEvent, Event, Level) of
        Level ->
            State;
        NewLevel ->
            NewState = State#encoder_state{nesting_level = NewLevel},
            maybe_update_indent(NewState)
    end.

do_update_nesting(array_start, array_end, Level) ->
    Level;
do_update_nesting(object_start, object_end, Level) ->
    Level;
do_update_nesting(LastEvent, _Event, Level)
  when LastEvent =:= array_start;
       LastEvent =:= object_start ->
    Level + 1;
do_update_nesting(_LastEvent, Event, Level)
  when Event =:= array_end;
       Event =:= object_end ->
    true = (Level >= 1),
    Level - 1;
do_update_nesting(_LastEvent, _Event, Level) ->
    Level.

maybe_update_indent(#encoder_state{compact = true} = State) ->
    State;
maybe_update_indent(#encoder_state{nesting_level = Level,
                                   indent = Indent} = State) ->
    State#encoder_state{current_indent = binary:copy(Indent, Level)}.

maybe_update_breadcrumb(_Event, #encoder_state{strict = false} = State) ->
    State;
maybe_update_breadcrumb(object_start, State) ->
    add_breadcrumb(object, State);
maybe_update_breadcrumb(array_start, State) ->
    add_breadcrumb(array, State);
maybe_update_breadcrumb({kv_start, _}, State) ->
    add_breadcrumb(kv, State);
maybe_update_breadcrumb(object_end, State) ->
    del_breadcrumb(State);
maybe_update_breadcrumb(array_end, State) ->
    del_breadcrumb(State);
maybe_update_breadcrumb(kv_end, State) ->
    del_breadcrumb(State);
maybe_update_breadcrumb(_Event, State) ->
    State.

add_breadcrumb(Entity, #encoder_state{breadcrumb = Breadcrumb} = State) ->
    State#encoder_state{breadcrumb = [Entity | Breadcrumb]}.

del_breadcrumb(#encoder_state{breadcrumb = Breadcrumb} = State) ->
    State#encoder_state{breadcrumb = tl(Breadcrumb)}.

maybe_validate_event(_Event, #encoder_state{strict = false}) ->
    ok;
maybe_validate_event(Event, State) ->
    case validate_event(Event, State) of
        true ->
            ok;
        false ->
            error({invalid_json, Event, State})
    end.

validate_event(array_end, State) ->
    validate_nesting(array, State);
validate_event(object_end, State) ->
    validate_nesting(object, State);
validate_event(kv_end, State) ->
    validate_nesting(kv, State);
validate_event({kv_start, _}, State) ->
    validate_nesting(object, State);
validate_event(_Event, #encoder_state{breadcrumb = [],
                                      last_event = Last})
  when Last =/= start ->
    %% allow only one top-level object
    false;
validate_event(_Event, _State) ->
    true.

validate_nesting(Expected, #encoder_state{breadcrumb = [Expected|_]}) ->
    true;
validate_nesting(_Expected, _State) ->
    false.

maybe_add_separator(Event, _State)
  when Event =:= object_end;
       Event =:= array_end;
       Event =:= kv_end ->
    <<>>;
maybe_add_separator(_Event, #encoder_state{last_event = Event}) ->
    do_maybe_add_separator(Event).

do_maybe_add_separator(other) ->
    <<",">>;
do_maybe_add_separator(kv_start) ->
    <<":">>;
do_maybe_add_separator(_) ->
    <<>>.

maybe_prettify(_Event, #encoder_state{compact = true}) ->
    <<>>;
maybe_prettify(Event, #encoder_state{last_event = LastEvent,
                                     current_indent = CurrentIndent}) ->
    do_prettify(LastEvent, Event, CurrentIndent).

do_prettify(array_start, array_end, _) ->
    <<>>;
do_prettify(object_start, object_end, _) ->
    <<>>;
do_prettify(_, kv_end, _) ->
    <<>>;
do_prettify(start, _, _) ->
    <<>>;
do_prettify(kv_start, _, _) ->
    <<" ">>;
do_prettify(_, _, Indent) ->
    [$\n, Indent].

encode_event({literal, Literal}) ->
    encode_literal(Literal);
encode_event(array_start) ->
    <<"[">>;
encode_event(array_end) ->
    <<"]">>;
encode_event(object_start) ->
    <<"{">>;
encode_event(object_end) ->
    <<"}">>;
encode_event({kv_start, Key}) ->
    encode_string(Key);
encode_event(kv_end) ->
    <<>>.

maybe_emit_final_newline(#encoder_state{compact = true}) ->
    ok;
maybe_emit_final_newline(State) ->
    emit([$\n], State).

emit(Encoded, #encoder_state{yield = Yield}) ->
    case misc:iolist_is_empty(Encoded) of
        true ->
            ok;
        false ->
            Yield(Encoded)
    end.

walk_json(Fun, {KVs}) ->
    Fun(object_start),
    lists:foreach(
      fun (KV) ->
              walk_json_kv(Fun, KV)
      end, KVs),
    Fun(object_end);
walk_json(Fun, Array) when is_list(Array) ->
    Fun(array_start),
    lists:foreach(
      fun (Elem) ->
              walk_json(Fun, Elem)
      end, Array),
    Fun(array_end);
walk_json(Fun, Literal) ->
    {true, Literal} = {is_literal(Literal), Literal},
    Fun({literal, Literal}).

walk_json_kv(Fun, {K, V}) ->
    {true, K} = {is_string(K), K},
    Fun({kv_start, K}),
    walk_json(Fun, V),
    Fun(kv_end).

is_literal(Json) ->
    is_number(Json) orelse is_string(Json) orelse is_null(Json).

is_string(Json) ->
    is_atom(Json) orelse is_binary(Json).

is_null(Json) ->
    Json =:= null.

encode_literal(Literal) ->
    {true, Literal} = {is_literal(Literal), Literal},
    ejson:encode(Literal).

encode_string(String) ->
    {true, String} = {is_string(String), String},
    ejson:encode(String).

-ifdef(EUNIT).
do_test_stream_json(Json, Expected) ->
    Result = pipes:run(stream_json(Json), pipes:collect()),
    ?assertEqual(Expected, Result).

stream_json_test() ->
    do_test_stream_json(1, [{literal, 1}]),
    do_test_stream_json(1.0, [{literal, 1.0}]),
    do_test_stream_json(null, [{literal, null}]),
    do_test_stream_json(atom, [{literal, atom}]),
    do_test_stream_json(<<"binary">>, [{literal, <<"binary">>}]),
    do_test_stream_json({[{k, v}]},
                        [object_start,
                         {kv_start, k},
                         {literal, v},
                         kv_end,
                         object_end]),
    do_test_stream_json([1, null, {[]}],
                        [array_start,
                         {literal, 1},
                         {literal, null},
                         object_start,
                         object_end,
                         array_end]).

prop_compact_encode_equals_to_ejson_encode() ->
    ?FORALL(Json, json(),
            ejson:encode(Json) =:=
                iolist_to_binary(
                  pipes:run(sjson:stream_json(Json),
                            sjson:encode_json([{compact, true},
                                               {strict, true}]),
                            pipes:collect()))).

prop_pretty_encode_isomorphic_to_ejson_encode() ->
    ?FORALL(Json, json(),
            ejson:decode(ejson:encode(Json)) =:=
                ejson:decode(
                  iolist_to_binary(
                    pipes:run(sjson:stream_json(Json),
                              sjson:encode_json([{compact, false},
                                                 {strict, true}]),
                              pipes:collect())))).


%% json generator
json() ->
    oneof([json_number(),
           json_string(),
           json_bool(),
           json_null(),
           json_array(),
           json_object()]).

smaller_json() ->
    triq_utils:smaller(?DELAY(json())).

json_number() ->
    oneof([int(), real()]).

json_string() ->
    oneof([json_string_binary(),
           json_string_atom()]).

json_string_binary() ->
    %% unicode_binary expects the size to be at least 2
    triq_utils:min_size(unicode_binary(), 2).

json_string_atom() ->
    ?SUCHTHAT(X,
              %% limit the size to prevent overflowing of atom table
              resize(4, atom()),
              not lists:member(X, [null, true, false])).

json_bool() ->
    bool().

json_null() ->
    null.

json_array() ->
    list(smaller_json()).

json_object() ->
    {list(json_object_kv())}.

json_object_kv() ->
    {json_string(), smaller_json()}.

-endif.
