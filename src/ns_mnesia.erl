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

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-record(state, {}).

%% API
-export([promote/1,
         promote_self/1,
         delete_schema/0,
         demote/1,
         ensure_table/2,
         prepare_rename/0,
         rename_node/2,
         start_link/0,
         truncate/2]).

%% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2,
         handle_info/2, init/1, terminate/2]).

%%
%% API
%%

%% @doc Demote a peer to a worker. If the node is down, you need to
%% eject it.
demote(Node) ->
    try gen_server:call({?MODULE, Node}, demote_self, 30000)
    catch E:R ->
            ?log_info("Failed to tell the remote node to demote itself: ~p",
                      [{E, R}])
    end,
    gen_server:call(?MODULE, {demote, Node}).


%% @doc Delete the current mnesia schema for joining/renaming purposes.
delete_schema() ->
    false = misc:running(?MODULE),
    %% Shut down mnesia in case something else started it.
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    ?log_info("Deleted schema.~nCurrent config: ~p",
              [mnesia:system_info(all)]).


%% @doc Make sure table exists and has a copy on this node, creating it or
%% adding a copy if it does not.
ensure_table(TableName, Opts) ->
    gen_server:call(?MODULE, {ensure_table, TableName, Opts}, 30000).


%% @doc Back up the database in preparation for a node rename.
prepare_rename() ->
    gen_server:call(?MODULE, prepare_rename).


%% @doc Promote a node that's already in the cluster to a peer.
promote(Node) ->
    gen_server:call({?MODULE, Node}, {promote_self, node()}, 30000).


%% @doc Promote *this* node by joining another node.
promote_self(OtherNode) ->
    gen_server:call(?MODULE, {promote_self, OtherNode}, 30000).


%% @doc Rename a node. Assumes there is only one node. Leaves Mnesia
%% stopped with no schema and a backup installed as a fallback. Finish
%% renaming the node and start Mnesia back up and you should have all
%% your data back. If for some reason you need to go back, you could
%% install the pre_rename backup as fallback and start Mnesia.
rename_node(From, To) ->
    gen_server:call(?MODULE, {rename_node, From, To}).


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


handle_call({demote, Node}, _From, State) ->
    %% Remove a node from the mnesia cluster after it's been disconnected.
    {atomic, ok} = mnesia:del_table_copy(schema, Node),
    {reply, ok, State};

handle_call(demote_self, _From, State) ->
    %% Back up, remove the schema from disk, then restart. The
    %% initialization routines will handle declustering.
    case mnesia:system_info(db_nodes) == [node()]
        andalso non_local_tables() == [] of
        true ->
            %% No-op if it's not a peer
            {reply, ok, State};
        false ->
            _ = backup(),
            stopped = mnesia:stop(),
            ok = mnesia:delete_schema([node()]),
            ?log_info("Demoting. Deleted local schema. Mnesia info:~n~p",
                      [mnesia:system_info(all)]),
            {ok, State1} = init([]),
            {reply, ok, State1}
    end;

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
                                     TableName, node(), disc_copies),
                    ok
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
    %% We need to back up the db before changing the node name,
    %% because it will fail if the node name doesn't match the schema.
    _ = backup(),
    {reply, ok, State};

handle_call({promote_self, Node}, _From, State) ->
    case mnesia:system_info(db_nodes) of
        [N] when N == node() ->
            %% Even though we use local_content tables, it's impossible to
            %% merge them, so instead we backup and restore.
            ?log_info("Promoting this node to a peer.", []),
            Tables = backup(),
            stopped = mnesia:stop(),
            ok = mnesia:delete_schema([node()]),
            start_mnesia(),
            %% Connect to an existing peer
            {ok, [Node]} = mnesia:change_config(extra_db_nodes, [Node]),
            %% Write the schema to disk
            restore(Tables, 10);
        _ ->
            %% Only promote if we're not already a peer
            ?log_error("Attempt to promote even though we're already a peer.",
                       []),
            ok
    end,
    {reply, ok, State};

handle_call({rename_node, From, To}, _From, _State) ->
    ?log_info("Renaming node from ~p to ~p.", [From, To]),
    stopped = mnesia:stop(),
    change_node_name(From, To),
    ok = mnesia:delete_schema([node()]),
    {ok, State1} = init([]),
    {reply, ok, State1};

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
    case is_mnesia_running() of
        yes ->
            ok;
        no ->
            case mnesia:system_info(db_nodes) of
                [Node] when Node == node() ->
                    %% Check for a backup, but only if we're the only
                    %% node
                    BackupFile = backup_file(),
                    case file:read_file_info(BackupFile) of
                        {ok, _} ->
                            ?log_info("Found backup. Restoring Mnesia database.", []),
                            %% Restore from backup, declustering first
                            %% to ensure we don't reconnect.
                            decluster(BackupFile),
                            ok = mnesia:install_fallback(BackupFile),
                            start_mnesia(),
                            %% Remove all tables that aren't local; we
                            %% should only have non-local tables if
                            %% we're a peer, which we can't be if
                            %% we're restoring from backup.
                            NonLocalTables = non_local_tables(),
                           ?log_info("Removing non-local tables ~p",
                                      [NonLocalTables]),
                            ok = mnesia:wait_for_tables(NonLocalTables, 5000),
                            lists:foreach(
                              fun (Table) ->
                                      {atomic, ok} = mnesia:delete_table(Table)
                              end, NonLocalTables),
                            ok = file:delete(BackupFile);
                        {error, enoent} ->
                            %% Crash if it's not one of these
                            start_mnesia(),
                            ensure_schema()
                    end;
                _ ->
                    start_mnesia(),
                    ensure_schema()
            end
    end,
    ?log_info("Current config: ~p", [mnesia:system_info(all)]),
    {ok, #state{}}.


terminate(Reason, _State) ->
    stopped = mnesia:stop(),
    ?log_info("Shut Mnesia down: ~p. Exiting.", [Reason]),
    ok.


%%
%% Internal functions
%%

%% @doc Back up the database to a standard location.
backup() ->
    %% Only back up if there is a disc copy of the schema somewhere
    case mnesia:table_info(schema, disc_copies) of
        [] ->
            ?log_info("No local copy of the schema. Skipping backup.", []),
            [];
        _ ->
            Tables = [Table || Table <- mnesia:system_info(local_tables),
                               mnesia:table_info(Table, local_content)],
            {ok, Name, _} = mnesia:activate_checkpoint([{min, [schema|Tables]}]),
            ok = mnesia:backup_checkpoint(Name, backup_file()),
            ok = mnesia:deactivate_checkpoint(Name),
            ?log_info("Backed up tables ~p", [Tables]),
            Tables
    end.


%% @doc The backup location.
backup_file() ->
    tmpdir("mnesia_backup").


%% Shamelessly stolen from Mnesia docs.
change_node_name(From, To) ->
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
    Source = backup_file(),
    Target = tmpdir("post_rename"),
    {ok, switched} = mnesia:traverse_backup(Source, mnesia_backup, Target,
                                            mnesia_backup, Convert, switched),
    ok = file:rename(Target, Source),
    ok.


%% @doc Traverse the backup, removing all nodes except this one.
decluster(Source) ->
    Node = node(),
    Convert =
        fun({schema, db_nodes, _}, Acc) ->
                {[{schema, db_nodes, [Node]}], Acc};
           ({schema, version, Version}, Acc) ->
                {[{schema, version, Version}], Acc};
           ({schema, cookie, Cookie}, Acc) ->
                {[{schema, cookie, Cookie}], Acc};
           ({schema, Tab, CreateList}, Acc) ->
                Keys = [ram_copies, disc_copies, disc_only_copies],
                OptSwitch =
                    fun({Key, Val}) ->
                            case lists:member(Key, Keys) of
                                true ->
                                    {Key, case lists:member(Node, Val) of
                                              true -> [Node];
                                              false -> []
                                          end};
                                false->
                                    {Key, Val}
                            end
                    end,
                {[{schema, Tab, lists:map(OptSwitch, CreateList)}], Acc};
           (Tuple, Acc) ->
                {[Tuple], Acc}
        end,
    Target = tmpdir("mnesia_declustered"),
    {ok, switched} = mnesia:traverse_backup(Source, mnesia_backup, Target,
                                            mnesia_backup, Convert, switched),
    ok = file:rename(Target, Source),
    ok.


%% @doc Make sure we have a disk copy of the schema and all disc tables.
ensure_schema() ->
    %% Create a new on-disk schema if one doesn't already exist
    Nodes = mnesia:table_info(schema, disc_copies),
    case lists:member(node(), Nodes) of
        false ->
            case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                {atomic, ok} ->
                    ?log_info("Committed schema to disk.", []);
                {aborted, {already_exists, _, _, _}} ->
                    ?log_warning("Failed to write schema. Retrying.~n"
                                 "Config = ~p", [mnesia:system_info(all)]),
                    timer:sleep(500),
                    ensure_schema()
            end;
        true ->
            ?log_info("Using existing disk schema on ~p.", [Nodes])
    end,
    %% Lay down copies of all the tables.
    Tables = mnesia:system_info(tables) -- [schema],
    lists:foreach(
      fun (Table) ->
              case mnesia:add_table_copy(Table, node(), disc_copies) of
                  {atomic, ok} ->
                      ?log_info("Created local copy of ~p", [Table]);
                  {aborted, {already_exists, _, _}} ->
                      ?log_info("Have local copy of ~p", [Table])
              end
      end, Tables),
    ok = mnesia:wait_for_tables(Tables, 2500).


%% @doc List of tables that aren't local_content.
non_local_tables() ->
    [Table || Table <- mnesia:system_info(tables),
              Table /= schema,
              not mnesia:table_info(Table, local_content)].


%% @doc Return yes or no depending on if mnesia is running, or {error,
%% Reason} if something is wrong.
is_mnesia_running() ->
    case mnesia:wait_for_tables([schema], 2500) of
        ok ->
            yes;
        {error, {node_not_running, _}} ->
            no;
        E -> E
    end.


restore(_Tables, 0) ->
    exit(restore_failed);
restore(Tables, Tries) ->
    ensure_schema(), % Lay down copies of any new tables
    KeepTables = mnesia:system_info(tables),
    CreateTables = Tables -- KeepTables,
    %% Restore our old data to the new tables
    case mnesia:restore(
           backup_file(),
           [{keep_tables, KeepTables},
            {recreate_tables, CreateTables}]) of
        {atomic, _} ->
            ?log_info("Successfully restored from backup. KeepTables = ~p, "
                      "CreateTables = ~p", [KeepTables, CreateTables]),
            ok = file:delete(backup_file()),
            ok;
        {aborted, {no_exists, T}} ->
            %% We're probably restoring precisely when another node
            %% created a table. Sleep and try again. MB-3415
            ?log_info("Probable collision restoring ~p. Retrying.", [T]),
            timer:sleep(500),
            restore(Tables, Tries-1)
    end.


%% @doc Start mnesia and wait for it to come up.
start_mnesia() ->
    ok = mnesia:start(),
    {ok, _} = mnesia:subscribe(system),
    {ok, _} = mnesia:subscribe({table, schema, detailed}),
    ok = mnesia:wait_for_tables([schema], 30000).


%% @doc Hack.
tmpdir() ->
    ns_config_default:default_path("tmp").


tmpdir(Filename) ->
    Path = filename:join(tmpdir(), Filename),
    ok = filelib:ensure_dir(Path),
    Path.


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


%%
%% Tests
%%

shutdown_child(Pid) ->
    exit(Pid, shutdown),
    receive
        {'EXIT', Pid, shutdown} ->
            ok;
        {'EXIT', Pid, Reason} ->
            exit({shutdown_failed, Reason})
    after 5000 ->
            ?log_error("Mnesia shutdown timed out", []),
            exit(Pid, kill),
            exit(shutdown_timeout)
    end.


startup_test() ->
    _ = file:delete(backup_file()),
    process_flag(trap_exit, true),
    Node = node(),
    ok = mnesia:delete_schema([Node]),
    {ok, Pid} = start_link(),
    yes = mnesia:system_info(is_running),
    [Node] = mnesia:table_info(schema, disc_copies),
    receive
        {'EXIT', Pid, Reason} ->
            exit({child_exited, Reason})
    after 0 -> ok
    end,
    shutdown_child(Pid).


decluster_test() ->
    _ = file:delete(backup_file()),
    process_flag(trap_exit, true),
    Node = node(),
    ok = mnesia:delete_schema([Node]),
    {ok, Pid} = start_link(),
    %% Create a disk-based table to make sure it gets removed
    ensure_table(test_disc, []),
    ensure_table(test_local, [{local_content, true}]),
    gen_server:call(?MODULE, demote_self),
    ?assertEqual([schema, test_local],
                 lists:sort(mnesia:system_info(local_tables))),
    shutdown_child(Pid).
