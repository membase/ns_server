%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
%% @doc Manage mnesia
%%
-module(ns_mnesia).

-include("ns_common.hrl").

-behaviour(gen_server).

-record(state, {}).

%% API
-export([delete_node/1, delete_schema/0,
         ensure_table/2,
         prepare_rename/0, rename_node/2,
         start_link/0,
         truncate/2]).

%% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2,
         handle_info/2, init/1, terminate/2]).

%%
%% API
%%

%% @doc Remove an mnesia node. Mnesia should be down on the remote node.
delete_node(Node) ->
    Result = mnesia:del_table_copy(schema, Node),
    ?log_info("Result of attempt to delete schema from ~p: ~p"
              "~nMnesia system info: ~p",
              [Node, Result, mnesia:system_info(all)]).


%% @doc Delete the current mnesia schema for joining/renaming purposes.
delete_schema() ->
    false = misc:running(?MODULE),
    ok = mnesia:delete_schema([node()]),
    ?log_info("Deleted schema.~nCurrent config: ~p",
              [mnesia:system_info(all)]).


%% @doc Make sure table exists and has a copy on this node, creating it or
%% adding a copy if it does not.
ensure_table(TableName, Opts) ->
    gen_server:call(?MODULE, {ensure_table, TableName, Opts}).


%% @doc Back up the database in preparation for a node rename.
prepare_rename() ->
    gen_server:call(?MODULE, prepare_rename).


%% @doc Rename a node. Assumes there is only one node. Leaves Mnesia
%% stopped with no schema and a backup installed as a fallback. Finish
%% renaming the node and start Mnesia back up and you should have all
%% your data back. If for some reason you need to go back, you could
%% install the pre_rename backup as fallback and start Mnesia.
rename_node(From, To) ->
    false = misc:running(?MODULE),
    ?log_info("Renaming node from ~p to ~p.", [From, To]),
    Pre = tmpdir("pre_rename"),
    Post = tmpdir("post_rename"),
    change_node_name(mnesia_backup, From, To, Pre, Post),
    ?log_info("Deleting old schema.", []),
    ok = mnesia:delete_schema([node()]),
    ?log_info("Installing new backup as fallback.", []),
    ok = mnesia:install_fallback(Post).


%% @doc Start the gen_server
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% @doc Truncate the given table to the last N records.
truncate(Tab, N) ->
    {atomic, _M} = mnesia:transaction(
                     fun () -> truncate(Tab, mnesia:last(Tab), N, 0) end).


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({add_node, Node}, _From, State) ->
    ?log_info("Adding node ~p. Connected nodes: ~p Mnesia config: ~n~p",
              [Node, nodes(), mnesia:system_info(all)]),
    {ok, [Node]} = mnesia:change_config(extra_db_nodes, [Node]),
    case mnesia:change_table_copy_type(schema, Node, disc_copies) of
        {atomic, ok} ->
            ?log_info("Added node ~p to cluster.",
                      [Node]);
        {aborted, {already_exists, _, _, _}} ->
            ?log_warning("Node ~p was already in cluster.", [Node])
    end,
    ?log_info("Mnesia config:~n~p", [mnesia:system_info(all)]),
    {reply, ok, State};

handle_call({ensure_table, TableName, Opts}, _From, State) ->
    try mnesia:table_info(TableName, disc_copies) of
        Nodes when is_list(Nodes) ->
            case lists:member(node(), Nodes) of
                true ->
                    ok;
                false ->
                    ?log_info("Creating local copy of ~p",
                              [TableName]),
                    {atomic, ok} = mnesia:add_table_copy(
                                     TableName, node(), disc_copies)
            end
    catch exit:{aborted, {no_exists, _, _}} ->
            {atomic, ok} =
                mnesia:create_table(
                  TableName,
                  Opts ++ [{disc_copies, [node()]}]),
            ?log_info("Created table ~p", [TableName])
    end,
    {reply, ok, State};

handle_call(prepare_rename, _From, State) ->
    Pre = tmpdir("pre_rename"),
    Reply = mnesia:backup(Pre),
    {reply, Reply, State};

handle_call(Request, From, State) ->
    ?log_warning("Unexpected call from ~p: ~p", [From, Request]),
    {reply, unhandled, State}.


handle_cast(Msg, State) ->
    ?log_warning("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


handle_info({mnesia_system_event, Event}, State) ->
    case Event of
        {mnesia_error, Format, Args} ->
            ?log_error("Error from Mnesia:~n" ++ Format, Args),
            {noreply, State};
        {mnesia_fatal, Format, Args, _} ->
            ?log_error("Fatal Mnesia error, exiting:~n" ++ Format, Args),
            timer:sleep(3000),
            {stop, mnesia_fatal, State};
        {mnesia_info, Format, Args} ->
            ?log_info("Info from Mnesia:~n" ++ Format, Args),
            {noreply, State};
        {mnesia_down, Node} ->
            ?log_info("Saw Mnesia go down on ~p", [Node]),
            {noreply, State};
        {mnesia_up, Node} ->
            ?log_info("Saw Mnesia come up on ~p", [Node]),
            {noreply, State};
        {mnesia_overload, {What, Why}} ->
            ?log_warning("Mnesia detected overload during ~p because of ~p",
                         [What, Why]),
            {noreply, State};
        {inconsistent_database, running_partitioned_network, Node} ->
            ?log_warning("Network partition detected with ~p. Restarting.",
                         [Node]),
            {stop, partitioned, State};
        {inconsistent_database, starting_partitioned_network, Node} ->
            %% TODO do we need to do something in this case?
            ?log_warning("Starting partitioned network with ~p.", [Node]),
            {noreply, State};
        _ ->
            ?log_info("Mnesia system event: ~p", [Event]),
            {noreply, State}
    end;

handle_info({mnesia_table_event, Event}, State) ->
    ?log_info("Mnesia table event:~n~p", [Event]),
    {noreply, State};

handle_info({'EXIT', _Pid, Reason}, State) ->
    case Reason of
        normal ->
            {noreply, State};
        _ ->
            {stop, Reason, State}
    end;

handle_info(Msg, State) ->
    ?log_warning("Unexpected message: ~p", [Msg]),
    {noreply, State}.


init([]) ->
    process_flag(trap_exit, true),
    mnesia:set_debug_level(verbose),
    %% Don't hang forever if a node goes down when a transaction is in
    %% an unclear state
    application:set_env(mnesia, max_wait_for_decision, 10000),
    ok = mnesia:start(), % Will work even if it's already started
    {ok, _} = mnesia:subscribe(system),
    {ok, _} = mnesia:subscribe({table, schema, detailed}),
    %% Create a new on-disk schema if one doesn't already exist
    Nodes = mnesia:table_info(schema, disc_copies),
    case lists:member(node(), Nodes) of
        false ->
            case ns_node_disco:nodes_actual_other() -- Nodes of
                [] ->
                    ok;
                ExtraNodes ->
                    case mnesia:change_config(extra_db_nodes, ExtraNodes) of
                        {ok, []} ->
                            exit(mnesia_connect_failed);
                        {ok, ConnectedNodes} ->
                            ?log_info("Mnesia connected to ~p",
                                      [ConnectedNodes])
                    end
            end,
            ?log_info("Committing schema to disk.", []),
            {atomic, ok} =
                   mnesia:change_table_copy_type(schema, node(), disc_copies);
        true ->
            ?log_info("Using existing disk schema on ~p.", [Nodes])
    end,
    ?log_info("Current config: ~p", [mnesia:system_info(all)]),
    {ok, #state{}}.


terminate(_Reason, _State) ->
    stopped = mnesia:stop(),
    ?log_info("Shut Mnesia down. Exiting.", []),
    ok.


%%
%% Internal functions
%%

%% Shamelessly stolen from Mnesia docs.
change_node_name(Mod, From, To, Source, Target) ->
    Switch =
        fun(Node) when Node == From -> To;
           (Node) when Node == To -> throw({error, already_exists});
           (Node) -> Node
        end,
    Convert =
        fun({schema, db_nodes, Nodes}, Acc) ->
                {[{schema, db_nodes, lists:map(Switch,Nodes)}], Acc};
           ({schema, version, Version}, Acc) ->
                {[{schema, version, Version}], Acc};
           ({schema, cookie, Cookie}, Acc) ->
                {[{schema, cookie, Cookie}], Acc};
           ({schema, Tab, CreateList}, Acc) ->
                Keys = [ram_copies, disc_copies, disc_only_copies],
                OptSwitch =
                    fun({Key, Val}) ->
                            case lists:member(Key, Keys) of
                                true -> {Key, lists:map(Switch, Val)};
                                false-> {Key, Val}
                            end
                    end,
                {[{schema, Tab, lists:map(OptSwitch, CreateList)}], Acc};
           (Tuple, Acc) ->
                {[Tuple], Acc}
        end,
    {ok, switched} = mnesia:traverse_backup(Source, Mod, Target, Mod, Convert,
                                            switched),
    ok.


%% @doc Hack.
tmpdir() ->
    ns_config_default:default_path("tmp").


tmpdir(Filename) ->
    filename:join(tmpdir(), Filename).


truncate(_Tab, '$end_of_table', N, M) ->
    case N of
        0 -> M;
        _ -> -N
    end;
truncate(Tab, Key, 0, M) ->
    NextKey = mnesia:prev(Tab, Key),
    ok = mnesia:delete({Tab, Key}),
    truncate(Tab, NextKey, 0, M + 1);
truncate(Tab, Key, N, 0) ->
    truncate(Tab, mnesia:prev(Tab, Key), N - 1, 0).
