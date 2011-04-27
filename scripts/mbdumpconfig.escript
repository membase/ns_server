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

main([Path]) ->
    {ok, Data} = file:read_file(Path),
    [Config|_] = erlang:binary_to_term(Data),
    io:fwrite("~p~n", [Config]).
