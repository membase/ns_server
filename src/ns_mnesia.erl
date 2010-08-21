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

-export([add_node/1, backout_rename/0, delete_node/1, delete_schema/0,
         delete_schema_and_stop/0, prepare_rename/0, rename_node/2,
         start/0]).


%%
%% API
%%

%% @doc Add an mnesia node. The other node had better have called
%% delete_schema().
add_node(Node) ->
    {ok, [Node]} = mnesia:change_config(extra_db_nodes, [Node]),
    {atomic, ok} = mnesia:change_table_copy_type(schema, Node, disc_copies),
    ?log_info("Added node ~p to cluster.~nCurrent config: ~p",
              [Node, mnesia:system_info(all)]).


%% @doc Call this if you decide you don't need to rename after all.
backout_rename() ->
    ?log_info("Starting Mnesia from backup.", []),
    ok = mnesia:install_fallback(tmpdir("pre_rename")),
    do_start().


%% @doc Remove an mnesia node.
delete_node(Node) ->
    lists:foreach(fun (Table) ->
                          Result = mnesia:del_table_copy(Table, Node),
                          ?log_info("Result of attempt to delete ~p from ~p: ~p",
                                    [Table, Node, Result])
                  end, mnesia:system_info(tables)),
    ?log_info("Removed node ~p from cluster.~nCurrent config: ~p",
              [Node, mnesia:system_info(all)]).


%% @doc Delete the current mnesia schema for joining/renaming purposes.
delete_schema() ->
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]),
    do_start(),
    ?log_info("Deleted schema.~nCurrent config: ~p",
              [mnesia:system_info(all)]).


%% @doc Delete the schema, but stay stopped.
delete_schema_and_stop() ->
    ?log_info("Deleting schema and stopping Mnesia.", []),
    stopped = mnesia:stop(),
    ok = mnesia:delete_schema([node()]).


%% @doc Back up the database in preparation for a node rename.
prepare_rename() ->
    Pre = tmpdir("pre_rename"),
    case mnesia:backup(Pre) of
        ok ->
            ?log_info("Backed up database to ~p.", [Pre]),
            stopped = mnesia:stop(),
            ?log_info("Deleting old schema.", []),
            ok = mnesia:delete_schema([node()]),
            ok;
        E ->
            ?log_error("Could not back up database for rename: ~p", [E]),
            {backup_error, E}
    end.


%% @doc Rename a node. Assumes there is only one node. Leaves Mnesia
%% stopped with no schema and a backup installed as a fallback. Finish
%% renaming the node and start Mnesia back up and you should have all
%% your data back. If for some reason you need to go back, you could
%% install the pre_rename backup as fallback and start Mnesia.
rename_node(From, To) ->
    ?log_info("Renaming node from ~p to ~p.", [From, To]),
    Pre = tmpdir("pre_rename"),
    Post = tmpdir("post_rename"),
    change_node_name(mnesia_backup, From, To, Pre, Post),
    ?log_info("Installing new backup as fallback.", []),
    ok = mnesia:install_fallback(Post),
    do_start().


%% @doc Start Mnesia, creating a new schema if we don't already have one.
start() ->
    %% Create a new on-disk schema if one doesn't already exist
    case mnesia:create_schema([node()]) of
        ok ->
            ?log_info("Creating new disk schema.", []);
        {error, {_, {already_exists, _}}} ->
            ?log_info("Using existing disk schema.", [])
    end,
    do_start(),
    ?log_info("Current config: ~p", [mnesia:system_info(all)]).


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


%% @doc Start mnesia and monitor it
do_start() ->
    mnesia:set_debug_level(verbose),
    ok = mnesia:start(),
    {ok, _} = mnesia:subscribe(system),
    {ok, _} = mnesia:subscribe({table, schema, detailed}).


%% @doc Hack.
tmpdir() ->
    ns_config_default:default_path("tmp").


tmpdir(Filename) ->
    filename:join(tmpdir(), Filename).
