%% @author Couchbase <info@couchbase.com>
%% @copyright 2012 Couchbase, Inc.
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

-module(ns_version_info).

-behaviour(gen_server).
-include("ns_common.hrl").
-include("ns_version_info.hrl").

-export([start_link/0,
         local_version_info_props/0,
         get_version_info/1, get_known_nodes/0,
         node_compatible/2, nodes_compatible/2, cluster_compatible/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-define(TABLE, ?MODULE).
-record(state, {}).

-define(KNOWN_NODES, known_nodes).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_version_info(Node) ->
    lookup(Node).

get_known_nodes() ->
    {ok, R} = lookup(?KNOWN_NODES),
    R.

local_version_info_props() ->
    VersionStr = ns_info:version(ns_server),
    Version = base_version(VersionStr),

    [{version, Version},
     {raw_version, VersionStr},
     {compatible_versions, ?COMPATIBILITY_LIST}].

node_compatible(Node, Version) ->
    case lookup({Node, Version}) of
        {error, not_found} ->
            false;
        {ok, true} ->
            true
    end.

nodes_compatible(Nodes, Version) ->
    lists:all(
      fun (Node) ->
              node_compatible(Node, Version)
      end, Nodes).

cluster_compatible(Version) ->
    nodes_compatible(ns_node_disco:nodes_wanted(), Version).

%% gen_server callbacks
init([]) ->
    ?TABLE = ets:new(?TABLE, [named_table, set, protected,
                              {read_concurrency, true}]),

    ns_pubsub:subscribe_link(ns_doctor_event),
    ns_pubsub:subscribe_link(ns_node_disco_events),

    true = ets:insert_new(?TABLE, {?KNOWN_NODES, []}),
    NodesWanted = ns_node_disco:nodes_wanted(),
    NodeStatuses = ns_doctor:get_nodes(),

    dict:fold(
      fun (Node, Status, Acc) ->
              ok = process_node_status(Node, Status, NodesWanted),
              Acc
      end, ignored, NodeStatuses),

    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    {reply, unhandled, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({ns_node_disco_events, _OldNodes, NewNodes}, State) ->
    maybe_cleanup_nodes(NewNodes),
    {noreply, State};
handle_info({node_status, Node, Status}, State) ->
    ok = process_node_status(Node, Status),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% internal functions
base_version(VersionStr) ->
    {BaseVersion, _, _} = misc:parse_version(VersionStr),
    BaseVersionStr = string:join(lists:map(fun integer_to_list/1, BaseVersion), "."),
    list_to_atom(BaseVersionStr).

process_node_status(Node, Status) ->
    process_node_status(Node, Status, ns_node_disco:nodes_wanted()).

process_node_status(Node, Status, NodesWanted) ->
    case ordsets:is_element(Node, NodesWanted) of
        true ->
            do_process_node_status(Node, Status);
        false ->
            ?log_info("Ignoring status from node ~p that's not in nodes wanted.",
                      [Node])
    end.

do_process_node_status(Node, Status) ->
    VersionInfoProps = proplists:get_value(version_info, Status, []),

    Version = proplists:get_value(version, VersionInfoProps, "unknown"),
    VersionStr = proplists:get_value(raw_version, VersionInfoProps, unknown),
    CompatibleVersions = proplists:get_value(compatible_versions,
                                             VersionInfoProps, []),

    VersionInfo =
        #version_info{version=Version,
                      raw_version=VersionStr,
                      compatible_versions=CompatibleVersions},

    case lookup(Node) of
        {error, not_found} ->
            Records = [{Node, VersionInfo} |
                       version_records(Node, CompatibleVersions)],
            true = ets:insert_new(?TABLE, Records),

            {ok, KnownNodes} = lookup(?KNOWN_NODES),

            false = ordsets:is_element(Node, KnownNodes),
            NewKnownNodes = ordsets:add_element(Node, KnownNodes),

            true = ets:insert(?TABLE, {?KNOWN_NODES, NewKnownNodes});
        {ok, #version_info{version=Version}} ->
            %% nothing to do
            ok;
        {ok, #version_info{compatible_versions=OldCompatibleVersions}} ->
            ToAdd = CompatibleVersions -- OldCompatibleVersions,
            ToDelete = OldCompatibleVersions -- CompatibleVersions,

            lists:foreach(
              fun (V) ->
                      true = ets:delete(?TABLE, {Node, V})
              end, ToDelete),

            true = ets:insert(?TABLE, {Node, VersionInfo}),
            true = ets:insert_new(?TABLE, version_records(Node, ToAdd))
    end,

    ok.

version_records(Node, CompatibleVersions) ->
    [{{Node, Version}, true} || Version <- CompatibleVersions].

maybe_cleanup_nodes(NewNodes) ->
    {ok, KnownNodes} = lookup(?KNOWN_NODES),
    ToDelete = ordsets:subtract(KnownNodes, NewNodes),

    lists:foreach(
      fun (Node) ->
              cleanup_node(Node)
      end, ToDelete),

    NewKnownNodes = ordsets:subtract(KnownNodes, ToDelete),
    true = ets:insert(?TABLE, {?KNOWN_NODES, NewKnownNodes}).

cleanup_node(Node) ->
    {ok, VersionInfo} = lookup(Node),
    #version_info{compatible_versions=CompatibleVersions} = VersionInfo,
    Keys = [Node | [{Node, Version} || Version <- CompatibleVersions]],
    lists:foreach(
      fun (Key) ->
              true = ets:delete(?TABLE, Key)
      end, Keys).

%% Lookup a key in ?TABLE. Return only the corresponding value.
lookup(Key) ->
    case ets:lookup(?TABLE, Key) of
        [] ->
            {error, not_found};
        [{Key, Value}] ->
            {ok, Value}
    end.
