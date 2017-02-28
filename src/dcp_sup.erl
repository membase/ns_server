%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
%% @doc suprevisor for dcp_replicator's
%%
-module(dcp_sup).

-behavior(supervisor).

-include("ns_common.hrl").

-export([start_link/1, init/1]).

-export([get_children/1, manage_replicators/3, nuke/1]).

start_link(Bucket) ->
    supervisor:start_link({local, server_name(Bucket)}, ?MODULE, []).

-spec server_name(bucket_name()) -> atom().
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.

get_children(Bucket) ->
    [{Node, C, T, M} ||
        {{Node, _XAttr}, C, T, M} <- supervisor:which_children(server_name(Bucket))].

build_child_spec(Bucket, {ProducerNode, XAttr} = ChildId) ->
    {ChildId,
     {dcp_replicator, start_link, [ProducerNode, Bucket, XAttr]},
     temporary, 60000, worker, [dcp_replicator]}.

start_replicator(Bucket, {ProducerNode, XAttr} = ChildId) ->
    ?log_debug("Starting DCP replication from ~p for bucket ~p (XAttr = ~p)",
               [ProducerNode, Bucket, XAttr]),

    case supervisor:start_child(server_name(Bucket),
                                build_child_spec(Bucket, ChildId)) of
        {ok, _} -> ok;
        {ok, _, _} -> ok
    end.

kill_replicator(Bucket, {ProducerNode, XAttr} = ChildId) ->
    ?log_debug("Going to stop DCP replication from ~p for bucket ~p (XAttr = ~p)",
               [ProducerNode, Bucket, XAttr]),
    _ = supervisor:terminate_child(server_name(Bucket), ChildId),
    ok.

%% This is where we actually control the creation/deletion of DCP replicators.
%% If the cluster is not XATTR aware, which is indicated when 'XAttr' is set
%% to false, then the DCP connections will also not be XATTR aware. The fact
%% that the connections are not XATTR aware is encoded into the child ID. When
%% the cluster becomes XATTR aware ('XAttr' set to true) we need to kill the
%% existing replicators and recreate them with XATTR enabled. The way we
%% determine if recreation is needed is by comparing the 'XAttr' value (which
%% must be set to true) with the value stored in child ID (which must be false).
manage_replicators(Bucket, NeededNodes, XAttr) ->
    CurrNodes = [ChildId || {ChildId, _C, _T, _M} <-
                                supervisor:which_children(server_name(Bucket))],

    ExpectedNodes = [{Node, XAttr} || Node <- NeededNodes],

    [kill_replicator(Bucket, CurrId) || CurrId <- CurrNodes -- ExpectedNodes],
    [start_replicator(Bucket, NewId) || NewId <- ExpectedNodes -- CurrNodes].

nuke(Bucket) ->
    Children = try get_children(Bucket) of
                   RawKids ->
                       [{ProducerNode, Pid} || {ProducerNode, Pid, _, _} <- RawKids]
               catch exit:{noproc, _} ->
                       []
               end,

    ?log_debug("Nuking DCP replicators for bucket ~p:~n~p",
               [Bucket, Children]),
    misc:terminate_and_wait({shutdown, nuke}, [Pid || {_, Pid} <- Children]),

    Connections = dcp_replicator:get_connections(Bucket),
    misc:parallel_map(
      fun (ConnName) ->
              dcp_proxy:nuke_connection(consumer, ConnName, node(), Bucket)
      end,
      Connections,
      infinity),
    Children =/= [] andalso Connections =/= [].
