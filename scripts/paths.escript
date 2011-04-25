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
%% @doc Given the path to the config and the name of the node, extract
%% the data directory.

main([Path, NodeStr]) ->
    {ok, Data} = file:read_file(Path),
    [Config|_] = erlang:binary_to_term(Data),
    Node = list_to_atom(NodeStr),
    {ok, DbDir} = ns_storage_conf:dbdir(Config),
    io:fwrite("~s~n", [DbDir]).
