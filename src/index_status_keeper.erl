%% @author Couchbase, Inc <info@couchbase.com>
%% @copyright 2015 Couchbase, Inc.
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
-module(index_status_keeper).

-include("ns_common.hrl").

-behavior(gen_server).

%% API
-export([start_link/0, update/2, get/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

update(NumConnections, Indexes) ->
    gen_server:cast(?MODULE, {update, NumConnections, Indexes}).

get(Timeout) ->
    gen_server:call(?MODULE, get, Timeout).

-record(state, {num_connections,
                indexes}).

init([]) ->
    {ok, #state{num_connections = 0, indexes = []}}.


handle_call(get, _From, State) ->
    {reply, [{num_connections, State#state.num_connections},
             {indexes, State#state.indexes}],
     State}.

handle_cast({update, NumConnections, Indexes}, _State) ->
    {noreply, #state{num_connections = NumConnections,
                     indexes = Indexes}}.

handle_info(Msg, State) ->
    ?log_debug("Ignoring unknown msg: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
