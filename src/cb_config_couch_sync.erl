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
%% @doc This server syncs part of (replicated) ns_config to local
%% couch config.  Actual sync is performed by worker process that's
%% direct son of supervisor. ns_config changes are noted by gen_server
%% process that's son of worker process. And it's using ns_pubsub to
%% tap into ns_config changes.
%%
%% Such seemingly unusual design (with worker being parent of main
%% process) is to ensure that supervisor shutdown synchronizes with
%% worker death (which mutates world state). Main process does not
%% mutate world's state, so worker can exit without waiting for main
%% process death (it'll die soon but we don't care when).

-module(cb_config_couch_sync).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

-export([start_link/0, set_db_and_ix_paths/2, get_db_and_ix_paths/0]).

%% gen_event callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-include("ns_common.hrl").

-record(state,
        {
          have_notable_change :: boolean(),
          sync_started :: boolean(),
          worker_pid :: pid()
        }).

start_link() ->
    proc_lib:start_link(erlang, apply, [fun start_worker_loop/0, []]).

start_worker_loop() ->
    erlang:process_flag(trap_exit, true),
    {ok, _} = gen_server:start_link({local, ?MODULE}, ?MODULE, [self()], []),
    do_config_sync(),
    proc_lib:init_ack({ok, self()}),
    worker_loop().

worker_loop() ->
    receive
        {'EXIT', _From, Reason} ->
            exit(Reason);
        {sync_config, Pid} ->
            do_config_sync(),
            Pid ! sync_done;
        X ->
            ?log_error("couch sync worker got unknown message: ~p~n", [X]),
            exit({unknown_message, X})
    end,
    worker_loop().

init([WorkerPid]) ->
    ns_pubsub:subscribe_link(ns_config_events, fun handle_config_event/2, []),
    {ok, maybe_start_sync(#state{have_notable_change = true,
                                 sync_started = false,
                                 worker_pid = WorkerPid})}.


-spec get_db_and_ix_paths() -> [{db_path | index_path, string()}].
get_db_and_ix_paths() ->
    DbPath = couch_config:get("couchdb", "database_dir"),
    IxPath = couch_config:get("couchdb", "view_index_dir", DbPath),
    [{db_path, DbPath},
     {index_path, IxPath}].

-spec set_db_and_ix_paths(DbPath :: string(), IxPath :: string()) -> ok.
set_db_and_ix_paths(DbPath, IxPath) ->
    couch_config:set("couchdb", "database_dir", DbPath),
    couch_config:set("couchdb", "view_index_dir", IxPath).

terminate(_Reason, _State) ->
    ok.
code_change(_OldVsn, State, _) ->
    {ok, State}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(notable_config_change, State) ->
    {noreply, maybe_start_sync(State#state{have_notable_change = true})};
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(sync_done, State) ->
    {noreply, maybe_start_sync(State#state{sync_started = false})};
handle_info(_Event, State) ->
    {noreply, State}.

%% Auxiliary functions.

is_notable_event({buckets, _}) -> true;
is_notable_event({autocompaction, _}) -> true;
is_notable_event(_) -> false.

handle_config_event(KVPair, State) ->
    case is_notable_event(KVPair) of
        true -> gen_server:cast(?MODULE, notable_config_change);
        _ -> ok
    end,
    State.

maybe_start_sync(#state{have_notable_change = false} = State) ->
    State;
maybe_start_sync(#state{sync_started = true} = State) ->
    State;
maybe_start_sync(#state{worker_pid = Pid} = State) ->
    Pid ! {sync_config, self()},
    State#state{have_notable_change = false,
                sync_started = true}.

build_compaction_config([]) ->
    [];
build_compaction_config([{database_fragmentation_threshold, {Perc, Size}} | ACRest]) ->
    [{db_fragmentation, {Perc, Size}} | build_compaction_config(ACRest)];
build_compaction_config([{view_fragmentation_threshold, {Perc, Size}} | ACRest]) ->
    [{view_fragmentation, {Perc, Size}} | build_compaction_config(ACRest)];
build_compaction_config([{parallel_db_and_view_compaction, V} | ACRest]) ->
    [{parallel_view_compaction, V} | build_compaction_config(ACRest)];
build_compaction_config([{allowed_time_period, KV} | ACRest]) ->
    From = integer_to_list(proplists:get_value(from_hour, KV))
         ++ ":" ++ integer_to_list(proplists:get_value(from_minute, KV)),
    To = integer_to_list(proplists:get_value(to_hour, KV))
        ++ ":" ++ integer_to_list(proplists:get_value(to_minute, KV)),
    StrictWindow = proplists:get_bool(abort_outside, KV),
    [{from, From},
     {to, To},
     {strict_window, StrictWindow}
     | build_compaction_config(ACRest)].

build_compaction_config_string(ACSettings) ->
    CouchSettings = lists:sort(build_compaction_config(ACSettings)),
    lists:flatten(io_lib:write(CouchSettings)).

do_config_sync() ->
    Config = ns_config:get(),
    sync_autocompaction(Config).

decide_autocompaction_config_changes(Config, CouchCompactionsList) ->
    CouchCompactions = dict:from_list(CouchCompactionsList),
    GlobalPair = {"_default",
                  case ns_config:search(Config, autocompaction) of
                      {value, ACConfig} ->
                          ACConfig;
                      _ ->
                          []
                  end},
    BucketConfigs0 = ns_bucket:get_buckets(Config),
    BucketConfigs1 = [{Name, proplists:get_value(autocompaction, KV, false)}
                      || {Name, KV} <- BucketConfigs0,
                         proplists:get_value(type, KV) =:= membase],
    BucketConfigs = lists:filter(fun ({_, false}) -> false;
                                     (_) -> true
                                 end, BucketConfigs1),
    NeededCompactions0 = [{Name, build_compaction_config_string(Cfg)}
                          || {Name, Cfg} <- [GlobalPair | BucketConfigs]],
    NeededCompactions = dict:from_list(NeededCompactions0),
    MissingCompactions = dict:fold(fun (Name, Cfg, Acc) ->
                                           case dict:find(Name, CouchCompactions) of
                                               {ok, Cfg} -> Acc; % note: Cfg is _already_ bound
                                               _ -> [{Name, Cfg} | Acc]
                                           end
                                   end, [], NeededCompactions),
    ExtraCompactions = dict:fold(fun (Name, _, Acc) ->
                                         case dict:find(Name, NeededCompactions) of
                                             error -> [Name | Acc];
                                             _ -> Acc
                                         end
                                 end, [], CouchCompactions),
    {MissingCompactions, ExtraCompactions}.

sync_autocompaction(Config) ->
    CouchCompactions = couch_config:get("compactions"),
    {MissingCompactions, ExtraCompactions} = decide_autocompaction_config_changes(Config, CouchCompactions),
    lists:foreach(fun ({Name, Cfg}) ->
                          couch_config:set("compactions", Name, Cfg)
                  end, MissingCompactions),
    lists:foreach(fun (Name) ->
                          couch_config:delete("compactions", Name)
                  end, ExtraCompactions).


-ifdef(EUNIT).
decide_autocompaction_config_changes_test() ->
    Cfg1 = [[{autocompaction,
              [{'_vclock',[{'n_0@192.168.2.168',{1,63481318861}}]},
               {parallel_db_and_view_compaction,true},
               {database_fragmentation_threshold,{66, 1024}},
               {view_fragmentation_threshold,{80, 1024}}]},
             {buckets,
              [{'_vclock',
                [{'n_0@127.0.0.1',{3,63481314227}},
                 {'n_0@192.168.2.168',{14,63481323468}}]},
               {configs,
                [{"mcd",
                  [{ram_quota,314572800},
                   {auth_type,sasl},
                   {sasl_password,[]},
                   {type,memcached},
                   {num_vbuckets,0},
                   {num_replicas,0},
                   {servers,['n_0@192.168.2.168']},
                   {map,[]}]},
                 {"default",
                  [{autocompaction,[{parallel_db_and_view_compaction,false}]},
                   {sasl_password,[]},
                   {auth_type,sasl},
                   {ram_quota,314572800},
                   {num_replicas,1},
                   {type,membase},
                   {num_vbuckets,16},
                   {servers,['n_0@192.168.2.168']},
                   {map, some_crap_here}]}]}]}]],
    CouchCompactions1 = [{"_default",
                          "[{db_fragmentation,{66,1024}},{parallel_view_compaction,true},{view_fragmentation,{80,1024}}]"},
                         {"default","[{parallel_view_compaction,false}]"}],
    ?assertEqual({[], []}, decide_autocompaction_config_changes(Cfg1, CouchCompactions1)),

    Cfg2 = [[{autocompaction,
              [{'_vclock',[{'n_0@192.168.2.168',{1,63481318861}}]},
               {parallel_db_and_view_compaction,true},
               {database_fragmentation_threshold,{66,1024}},
               {view_fragmentation_threshold,{80,1024}}]},
             {buckets,
              [{'_vclock',
                [{'n_0@127.0.0.1',{3,63481314227}},
                 {'n_0@192.168.2.168',{14,63481323468}}]},
               {configs,
                [{"mcd",
                  [{ram_quota,314572800},
                   {auth_type,sasl},
                   {sasl_password,[]},
                   {type,memcached},
                   {num_vbuckets,0},
                   {num_replicas,0},
                   {servers,['n_0@192.168.2.168']},
                   {map,[]}]},
                 {"default",
                  [{autocompaction,false},
                   {sasl_password,[]},
                   {auth_type,sasl},
                   {ram_quota,314572800},
                   {num_replicas,1},
                   {type,membase},
                   {num_vbuckets,16},
                   {servers,['n_0@192.168.2.168']},
                   {map, some_crap_here}]}]}]}]],
    CouchCompactions2 = [{"_default",
                          "[{db_fragmentation,{66,1024}},{parallel_view_compaction,true},{view_fragmentation,{80,1024}}]"},
                         {"default","[{parallel_view_compaction,false}]"}],
    ?assertEqual({[], ["default"]}, decide_autocompaction_config_changes(Cfg2, CouchCompactions2)),

    Cfg3 = [[{autocompaction,
              [{'_vclock',[{'n_0@192.168.2.168',{1,63481318861}}]},
               {parallel_db_and_view_compaction,true},
               {database_fragmentation_threshold,{66,1024}},
               {view_fragmentation_threshold,{80,1024}}]},
             {buckets,
              [{'_vclock',
                [{'n_0@127.0.0.1',{3,63481314227}},
                 {'n_0@192.168.2.168',{14,63481323468}}]},
               {configs,
                [{"mcd",
                  [{ram_quota,314572800},
                   {auth_type,sasl},
                   {sasl_password,[]},
                   {type,memcached},
                   {num_vbuckets,0},
                   {num_replicas,0},
                   {servers,['n_0@192.168.2.168']},
                   {map,[]}]},
                 {"default",
                  [{autocompaction,[{parallel_db_and_view_compaction,false},
                                    {database_fragmentation_threshold, {55, 1024}}]},
                   {sasl_password,[]},
                   {auth_type,sasl},
                   {ram_quota,314572800},
                   {num_replicas,1},
                   {type,membase},
                   {num_vbuckets,16},
                   {servers,['n_0@192.168.2.168']},
                   {map, some_crap_here}]}]}]}]],
    CouchCompactions3 = [{"_default",
                          "[{db_fragmentation,{66,1024}},{parallel_view_compaction,true},{view_fragmentation,{80,1024}}]"},
                         {"default","[{parallel_view_compaction,false}]"}],
    ?assertEqual({[{"default","[{db_fragmentation,{55,1024}},{parallel_view_compaction,false}]"}], []},
                 decide_autocompaction_config_changes(Cfg3, CouchCompactions3)).

-endif.
