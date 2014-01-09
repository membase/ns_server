%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
%% @doc this module implements gen_server API compatible to
%% lhttpc_manager but does keep any sockets at all. It's useful for
%% lhttpc requests that must use new connection.

-module(ns_null_connection_pool).

-export([start_link/1]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-behaviour(gen_server).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

%% @hidden
init([]) ->
    {ok, []}.

%% @hidden
handle_call({socket, _Pid, _Host, _Port, _Ssl}, _From, State) ->
    {reply, no_socket, State};
handle_call({done, _Host, _Port, Ssl, Socket}, From, State) ->
    gen_server:reply(From, ok),
    lhttpc_sock:close(Socket, Ssl),
    {noreply, State};
handle_call(_, _, State) ->
    {reply, {error, unknown_request}, State}.

%% @hidden
handle_cast(_, State) ->
    {noreply, State}.

%% @hidden
handle_info(_, State) ->
    {noreply, State}.

%% @hidden
terminate(_, _State) ->
    ok.

%% @hidden
code_change(_, State, _) ->
    {ok, State}.
