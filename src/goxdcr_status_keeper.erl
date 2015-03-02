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
-module(goxdcr_status_keeper).

-include("ns_common.hrl").

-behavior(gen_server).

%% API
-export([start_link/1,
         store_replications/2,
         get_replications/2,
         get_replications_with_remote_info/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)}, ?MODULE, [], []).

server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

store_replications(Bucket, Replications) ->
    gen_server:cast(server_name(Bucket), {store_replications, Replications}).

get_replications_with_remote_info(Bucket, Timeout) ->
    gen_server:call(server_name(Bucket), get_replications_with_remote_info, Timeout).

get_replications(Bucket, Timeout) ->
    [Id || {Id, _, _} <- get_replications_with_remote_info(Bucket, Timeout)].

init([]) ->
    {ok, []}.


handle_call(get_replications_with_remote_info, _From, Replications) ->
    {reply, Replications, Replications}.

handle_cast({store_replications, Replications}, _State) ->
    {noreply, Replications}.

handle_info(Msg, State) ->
    ?log_debug("Ignoring unknown msg: ~p", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
