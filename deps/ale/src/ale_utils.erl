%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(ale_utils).

-compile(export_all).

-include("ale.hrl").

-spec loglevel_to_integer(loglevel()) -> 0..4.
loglevel_to_integer(critical) -> 0;
loglevel_to_integer(error)    -> 1;
loglevel_to_integer(warn)     -> 2;
loglevel_to_integer(info)     -> 3;
loglevel_to_integer(debug)    -> 4.

-spec loglevel_enabled(loglevel(), loglevel()) -> boolean().
loglevel_enabled(LogLevel, ThresholdLogLevel) ->
    loglevel_to_integer(LogLevel) =< loglevel_to_integer(ThresholdLogLevel).

-spec assemble_info(atom(), loglevel(), atom(), atom(), integer(), any()) ->
                           #log_info{}.
assemble_info(Logger, LogLevel, Module, Function, Line, UserData) ->
    Time = now(),
    Self = self(),
    Process =
        case erlang:process_info(Self, registered_name) of
            {registered_name, ProcessName} ->
                ProcessName;
            _ -> Self
        end,
    Node = node(),

    #log_info{logger=Logger,
              loglevel=LogLevel,
              module=Module,
              function=Function,
              line=Line,
              time=Time,
              process=Process,
              node=Node,
              user_data=UserData}.

-spec force_args(list()) -> list().
force_args(Exprs) when is_list(Exprs) ->
    lists:map(fun force/1, Exprs).

-spec force(any()) -> any().
force({'_susp', _Ref, Susp}) ->
    Susp();
force(Other) ->
    Other.

-spec proplists_merge([{any(), any()}], [{any(), any()}],
                      fun((any(), any(), any()) -> any())) -> [{any(), any()}].
proplists_merge(Prop1, [], _Fn) ->
    Prop1;
proplists_merge([], [_|_] = Prop2, _Fn) ->
    Prop2;
proplists_merge([{Key, Value} = H | T], Prop2, Fn) ->
    {Head, Prop2Rest} =
        case proplists:lookup(Key, Prop2) of
            none ->
                {H, Prop2};
            {Key, OtherValue} ->
                {{Key, Fn(Key, Value, OtherValue)},
                 lists:filter(fun ({PKey, _Value}) -> PKey =/= Key end, Prop2)}
        end,
    [Head | proplists_merge(T, Prop2Rest, Fn)].

proplists_merge(Prop1, Prop2) ->
    First = fun (_Key, X, _Y) -> X end,
    proplists_merge(Prop1, Prop2, First).

child_id(NameSpace, Name) ->
    NameSpaceStr = atom_to_list(NameSpace),
    NameStr = atom_to_list(Name),

    IdStr = lists:append([NameSpaceStr, "-", NameStr]),
    list_to_atom(IdStr).

sink_id(Name) ->
    child_id(sink, Name).

supported_opts(UserOpts, Supported) ->
    UserKeys = proplists:get_keys(UserOpts),
    [] =:= UserKeys -- Supported.

interesting_opts(UserOpts, Interesting) ->
    Pred = fun ({Opt, _Value}) ->
                   lists:member(Opt, Interesting);
               (Opt) ->
                   lists:member(Opt, Interesting)
           end,
    lists:filter(Pred, UserOpts).
