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
-module(mb_mnesia).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-behaviour(gen_server).

-record(state, {peers = []}).

%% API
-export([delete_schema/0,
         ensure_table/2,
         maybe_rename/1,
         start_link/0,
         truncate/2,
         wipe/0]).

%% gen_server callbacks
-export([code_change/3, handle_call/3, handle_cast/2,
         handle_info/2, init/1, terminate/2]).


%%
%% API
%%

%% @doc Delete the current mnesia schema for joining/renaming purposes.
delete_schema() ->
    false = misc:running(?MODULE),
    %% Shut down mnesia in case something else started it.
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    ?log_debug("Deleted schema.~nCurrent config: ~p",
               [mnesia:system_info(all)]).


%% @doc Make sure table exists and has a copy on this node, creating it or
%% adding a copy if it does not.
ensure_table(TableName, Opts) ->
    gen_server:call(?MODULE, {ensure_table, TableName, Opts}, 30000).


%% @doc Possibly rename the node, if it's not clustered. Returns true
%% if it renamed the node, false otherwise.
maybe_rename(NewAddr) ->
    gen_server:call(?MODULE, {maybe_rename, NewAddr}, 30000).


%% @doc Start the gen_server
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


%% @doc Truncate the given table to the last N records.
truncate(Tab, N) ->
    {atomic, _M} = mnesia:transaction(
                     fun () -> truncate(Tab, mnesia:last(Tab), N, 0) end).


%% @doc Wipe all mnesia data.
wipe() ->
    gen_server:call(?MODULE, wipe, 30000).


%%
%% gen_server callbacks
%%

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


handle_call({ensure_table, TableName, Opts}, From, State) ->
    try mnesia:table_info(TableName, disc_copies) of
        Nodes when is_list(Nodes) ->
            case lists:member(node(), Nodes) of
                true ->
                    {reply, ok, State};
                false ->
                    ?log_debug("Creating local copy of ~p",
                               [TableName]),
                    do_with_timeout(
                      fun () ->
                              {atomic, ok} =
                                  mnesia:add_table_copy(TableName, node(),
                                                        disc_copies)
                      end, From, 5000),
                    {noreply, State}
            end
    catch exit:{aborted, {no_exists, _, _}} ->
            ?log_debug("Creating table ~p", [TableName]),
            do_with_timeout(
              fun () ->
                      {atomic, ok} =
                          mnesia:create_table(
                            TableName, Opts ++ [{disc_copies, [node()]}])
              end, From, 5000),
            {noreply, State}
    end;

handle_call({maybe_rename, NewAddr}, _From, State) ->
    %% We need to back up the db before changing the node name,
    %% because it will fail if the node name doesn't match the schema.
    backup(),
    OldName = node(),
    case dist_manager:adjust_my_address(NewAddr) of
        nothing ->
            ?log_debug("Not renaming node. Deleting backup.", []),
            ok = file:delete(backup_file()),
            {reply, false, State};
        net_restarted ->
            %% Make sure the cookie's still the same
            NewName = node(),
            ?log_debug("Renaming node from ~p to ~p.", [OldName, NewName]),
            stopped = mnesia:stop(),
            change_node_name(OldName, NewName),
            ok = mnesia:delete_schema([NewName]),
            {ok, State1} = init([]),
            {reply, true, State1}
    end;

handle_call(wipe, _From, State) ->
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    start_mnesia([ensure_schema]),
    {reply, ok, State};

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
            ?log_debug("Info from Mnesia:~n" ++ Format, Args),
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
            ?log_debug("Mnesia system event: ~p", [Event]),
            {noreply, State}
    end;

handle_info({mnesia_table_event, {write, {schema, cluster, L}, _}},
            State) ->
    NewPeers = proplists:get_value(disc_copies, L),
    ?log_debug("Peers: ~p", [NewPeers]),
    gen_event:notify(mb_mnesia_events, {peers, NewPeers}),
    {noreply, State#state{peers=NewPeers}};

handle_info({mnesia_table_event, Event}, State) ->
    ?log_debug("Mnesia table event:~n~p", [Event]),
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
                            ok = mnesia:install_fallback(BackupFile),
                            start_mnesia([]),
                            ok = file:delete(BackupFile);
                        {error, enoent} ->
                            %% Crash if it's not one of these
                            start_mnesia([ensure_schema])
                    end;
                _ ->
                    start_mnesia([ensure_schema])
            end
    end,
    Peers = ensure_config_tables(),
    ?log_debug("Current config:~n~p~nPeers: ~p",
               [mnesia:system_info(all), Peers]),
    %% Send an initial notification of our peer list.
    gen_event:notify(mb_mnesia_events, {peers, Peers}),
    {ok, #state{peers=Peers}}.


terminate(Reason, _State) when Reason == normal; Reason == shutdown ->
    stopped = mnesia:stop(),
    ?log_info("Shut Mnesia down: ~p. Exiting.", [Reason]),
    ok;

terminate(_Reason, _State) ->
    %% Don't shut down on crash
    ok.


%%
%% Internal functions
%%

%% @doc Back up the database to a standard location.
backup() ->
    backup(5).

backup(Tries) ->
    %% Only back up if there is a disc copy of the schema somewhere
    case mnesia:table_info(schema, disc_copies) of
        [] ->
            ?log_info("No local copy of the schema. Skipping backup.", []),
            ok;
        _ ->
            case mnesia:activate_checkpoint([{min, mnesia:system_info(tables)}]) of
                {ok, Name, _} ->
                    ok = mnesia:backup_checkpoint(Name, backup_file()),
                    ok = mnesia:deactivate_checkpoint(Name),
                    ok;
                {error, Err} ->
                    ?log_error("Error backing up: ~p (~B tries remaining)",
                               [Err, Tries]),
                    case Tries of
                        0 ->
                            exit({backup_error, Err});
                        _ ->
                            backup(Tries-1)
                    end
            end
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


%% @private
%% @doc Exit if Fun hasn't returned within the specified timeout.
-spec do_with_timeout(fun(), {pid(), any()}, non_neg_integer()) ->
                             ok.
do_with_timeout(Fun, Client, Timeout) ->
    {Pid, Ref} =
        spawn_monitor(
          fun () ->
                  Reply = Fun(),
                  gen_server:reply(Client, Reply)
          end),
    receive
        {'DOWN', Ref, _, _, Reason} ->
            case Reason of
                normal ->
                    ok;
                _ ->
                    %% We'll just let the caller time out, since we
                    %% have no idea if the worker actually tried to
                    %% send a reply.
                    ?log_error("Worker process exited with reason ~p",
                               [Reason]),
                    ok
            end
    after Timeout ->
            ?log_error("Worker process timed out. Killing it.", []),
            erlang:demonitor(Ref, [flush]),
            exit(Pid, kill),
            ok
    end.


%% @private @doc Make sure the config tables exist for bootstrapping a
%% new node. Returns the list of peers.
ensure_config_tables() ->
    %% We distinguish between worker and peer nodes by whether or not
    %% the "cluster" table exists. This could as easily be any other
    %% table we can be sure will exist on the nodes with clustered
    %% Mnesia, but it's best to have a table we create here for that
    %% purpose. In order to distinguish between a brand new node that
    %% may have crashed between laying down the schema and creating
    %% the cluster table, we create a local content table called
    %% local_config that is expected to exist on *all* nodes.
    try mnesia:table_info(cluster, disc_copies)
    catch exit:{aborted, {no_exists, _, _}} ->
            try mnesia:table_info(local_config, disc_copies) of
                _ ->
                    %% Not a new node, so a worker node
                    []
            catch exit:{aborted, {no_exists, _, _}} ->
                    %% New node; create cluster table first so we
                    %% can't get fooled by a crash into thinking
                    %% this is a worker node.
                    {atomic, ok} =
                        mnesia:create_table(
                          cluster, [{disc_copies, [node()]}]),
                    {atomic, ok} =
                        mnesia:create_table(
                          local_config, [{local_content, true},
                                         {disc_copies, [node()]}]),
                    [node()]
            end
    end.


%% @private
%% @doc Make sure we have a disk copy of the schema and all disc tables.
ensure_schema() ->
    %% Create a new on-disk schema if one doesn't already exist
    Nodes = mnesia:table_info(schema, disc_copies),
    case lists:member(node(), Nodes) of
        false ->
            case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                {atomic, ok} ->
                    ?log_debug("Committed schema to disk.", []);
                {aborted, {already_exists, _, _, _}} ->
                    ?log_warning("Failed to write schema. Retrying.~n"
                                 "Config = ~p", [mnesia:system_info(all)]),
                    timer:sleep(500),
                    ensure_schema()
            end;
        true ->
            ?log_debug("Using existing disk schema on ~p.", [Nodes])
    end,
    %% Lay down copies of all the tables.
    Tables = mnesia:system_info(tables) -- [schema],
    lists:foreach(
      fun (Table) ->
              case mnesia:add_table_copy(Table, node(), disc_copies) of
                  {atomic, ok} ->
                      ?log_debug("Created local copy of ~p", [Table]);
                  {aborted, {already_exists, _, _}} ->
                      ?log_debug("Have local copy of ~p", [Table])
              end
      end, Tables),
    ok = mnesia:wait_for_tables(Tables, 2500).


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


%% @doc Start mnesia and wait for it to come up.
start_mnesia(Options) ->
    do_start_mnesia(Options, false).

cleanup_and_start_mnesia(Options) ->
    MnesiaDir = path_config:component_path(data, "mnesia"),
    ToDelete = filelib:wildcard("*", MnesiaDir),
    ?log_info("Recovering from damaged mnesia files by deleting them:~n~p~n", [ToDelete]),
    lists:foreach(fun (BaseName) ->
                          file:delete(filename:join(MnesiaDir, BaseName))
                  end, ToDelete),
    do_start_mnesia(Options, true).

do_start_mnesia(Options, Repeat) ->
    EnsureSchema = proplists:get_bool(ensure_schema, Options),
    MnesiaDir = path_config:component_path(data, "mnesia"),
    application:set_env(mnesia, dir, MnesiaDir),
    case mnesia:start() of
        ok ->
            {ok, _} = mnesia:subscribe(system),
            {ok, _} = mnesia:subscribe({table, schema, simple}),
            case mnesia:wait_for_tables([schema], 30000) of
                {error, _} when Repeat =/= true ->
                    mnesia:unsubscribe({table, schema, simple}),
                    mnesia:unsubscribe(system),
                    stopped = mnesia:stop(),
                    cleanup_and_start_mnesia(Options);
                ok -> ok
            end;
        {error, _} when Repeat =/= true ->
            cleanup_and_start_mnesia(Options)
    end,
    case {EnsureSchema, Repeat} of
        {true, false} ->
            try
                ensure_schema()
            catch T:E ->
                    ?log_warning("ensure_schema failed: ~p:~p~n", [T,E]),
                    mnesia:unsubscribe({table, schema, simple}),
                    mnesia:unsubscribe(system),
                    stopped = mnesia:stop(),
                    cleanup_and_start_mnesia(Options)
            end;
        {true, _} ->
            ensure_schema();
        _ ->
            ok
    end.

%% @doc Hack.
tmpdir() ->
    path_config:component_path(tmp).


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

startup_test_() ->
    {spawn, fun () ->
                    ets:new(path_config_override, [public, named_table]),
                    ets:insert(path_config_override, {path_config_tmpdir, "./tmp"}),
                    ets:insert(path_config_override, {path_config_datadir, "./tmp"}),
                    _ = file:delete(backup_file()),
                    OldFlag = process_flag(trap_exit, true),
                    try
                        Node = node(),
                        ok = mnesia:delete_schema([Node]),
                        {ok, Pid} = mb_mnesia_sup:start_link(),
                        yes = mnesia:system_info(is_running),
                        [Node] = mnesia:table_info(schema, disc_copies),
                        receive
                            {'EXIT', Pid, Reason} ->
                                exit({child_exited, Reason})
                        after 0 -> ok
                        end,
                        shutdown_child(Pid)
                    after
                        process_flag(trap_exit, OldFlag)
                    end
            end}.
