#!/usr/bin/env escript
%% -*- erlang -*-
%%
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
%%
%% ------------------------------------------------------------------------
%%
%% @doc Dump a config.dat file to stdout.
%%
%% Examples:
%%  linux:
%%    ./bin/mbdumpconfig.escript var/lib/membase/config/config.dat
%%  windows:
%%    bin\erlang\escript bin\mbdumpconfig.escript var\lib\membase\config\config.dat
%%
%% To just get a list of bucket names of a particular type:
%%    mbdumpconfig.escript path/to/config.dat buckets BucketType
%%  Example:
%%    mbdumpconfig.escript path/to/config.dat buckets membase

read(Path) ->
    {ok, Data} = file:read_file(Path),
    [Config|_] = erlang:binary_to_term(Data),
    Config.

main([Path]) ->
    Config = read(Path),
    io:fwrite("~p~n", [Config]);

main([Path, "buckets", Type]) ->
    Config = read(Path),
    emit(buckets(Config, list_to_atom(Type))).

emit([]) -> ok;
emit([X | Rest]) ->
    io:fwrite("~s~n", [X]),
    emit(Rest).

buckets(Config, Type) ->
    keys(Type, proplists:get_value(configs, proplists:get_value(buckets, Config)), []).

keys(_Type, [], Acc) ->
    Acc;
keys(Type, [{Key, Val} | Rest], Acc) ->
    case proplists:get_value(type, Val) of
        Type -> keys(Type, Rest, [Key | Acc]);
        _    -> keys(Type, Rest, Acc)
    end.
