% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couchbase_compaction_daemon).
-behaviour(gen_server).

% public API
-export([start_link/0, config_change/3]).

% gen_server callbacks
-export([init/1, handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3, terminate/2]).

-include("couch_db.hrl").
-include("ns_common.hrl").

% If N vbucket databases of a bucket need to be compacted, we trigger compaction
% for all the vbucket databases of that bucket.
-define(NUM_SAMPLE_VBUCKETS, 4).

-define(CONFIG_ETS, couch_compaction_daemon_config).
% The period to pause for after checking (and eventually compact) all
% databases and view groups.
-define(DISK_CHECK_PERIOD, 1).          % minutes
-define(KV_RE,
    [$^, "\\s*", "([^=]+?)", "\\s*", $=, "\\s*", "([^=]+?)", "\\s*", $$]).
-define(PERIOD_RE,
    [$^, "([^-]+?)", "\\s*", $-, "\\s*", "([^-]+?)", $$]).

-record(state, {
    loop_pid
}).

-record(config, {
    db_frag = nil,
    view_frag = nil,
    period = nil,
    cancel = false,
    parallel_view_compact = false
}).

-record(period, {
    from = nil,
    to = nil
}).


start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).


init(_) ->
    process_flag(trap_exit, true),
    ?CONFIG_ETS = ets:new(?CONFIG_ETS, [named_table, set, protected]),
    ok = couch_config:register(fun ?MODULE:config_change/3),
    load_config(),
    case start_os_mon() of
    ok ->
        Server = self(),
        Loop = spawn_link(fun() -> compact_loop(Server) end),
        {ok, #state{loop_pid = Loop}};
    {error, Error} ->
        {stop, Error}
    end.


config_change("compactions", DbName, NewValue) ->
    ok = gen_server:cast(?MODULE, {config_update, DbName, NewValue}).


start_os_mon() ->
    case application:start(os_mon) of
    ok ->
        ok = disksup:set_check_interval(?DISK_CHECK_PERIOD);
    {error, {already_started, os_mon}} ->
        ok;
    {error, _} = Error ->
        Error
    end.


handle_cast({config_update, DbName, deleted}, State) ->
    true = ets:delete(?CONFIG_ETS, ?l2b(DbName)),
    {noreply, State};

handle_cast({config_update, DbName, Config}, #state{loop_pid = Loop} = State) ->
    case parse_config(DbName, Config) of
    {ok, NewConfig} ->
        WasEmpty = (ets:info(?CONFIG_ETS, size) =:= 0),
        true = ets:insert(?CONFIG_ETS, {?l2b(DbName), NewConfig}),
        case WasEmpty of
        true ->
            Loop ! {self(), have_config};
        false ->
            ok
        end;
    error ->
        ok
    end,
    {noreply, State}.


handle_call(Msg, _From, State) ->
    {stop, {unexpected_call, Msg}, State}.


handle_info({'EXIT', Pid, Reason}, #state{loop_pid = Pid} = State) ->
    {stop, {compaction_loop_died, Reason}, State}.


terminate(_Reason, _State) ->
    true = ets:delete(?CONFIG_ETS).


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


compact_loop(Parent) ->
    Me = node(),
    CouchbaseBuckets = lists:filter(
        fun ({_Name, Config}) ->
                ns_bucket:bucket_type(Config) =:= membase
        end,
        ns_bucket:get_buckets()),
    Buckets = lists:map(
        fun({Name, Config}) ->
            {_, VbNames} = lists:foldl(
                fun(Nodes, {Index, Acc}) ->
                    case lists:member(Me, Nodes) of
                    true ->
                        VbName = iolist_to_binary(
                            [Name, $/, integer_to_list(Index)]),
                        {Index + 1, [VbName | Acc]};
                    false ->
                        {Index + 1, Acc}
                    end
                end,
                {0, []}, couch_util:get_value(map, Config, [])),
            NameBin = ?l2b(Name),
            {NameBin, VbNames, bucket_compact_config(NameBin)}
        end,
        CouchbaseBuckets),
    lists:foreach(
        fun({_BucketName, _VbNames = [], _}) ->
            ok;
        ({_BucketName, _VbNames, nil}) ->
            ok;
        ({BucketName, VbNames, {ok, Config}}) ->
            maybe_compact_bucket(BucketName, VbNames, Config)
        end,
        Buckets),
    case ets:info(?CONFIG_ETS, size) =:= 0 of
    true ->
        receive {Parent, have_config} -> ok end;
    false ->
        PausePeriod = list_to_integer(
            couch_config:get("compaction_daemon", "check_interval", "1")),
        ok = timer:sleep(PausePeriod * 1000)
    end,
    compact_loop(Parent).


maybe_compact_bucket(BucketName, VbNames, Config) ->
    MasterDbName = <<BucketName/binary, "/master">>,
    DDocNames = case couch_db:open_int(MasterDbName, []) of
    {ok, MasterDb} ->
         Names = db_ddoc_names(MasterDb),
         couch_db:close(MasterDb),
         Names;
    Error ->
         ?log_error("Error opening database `~s`: ~p", [MasterDbName, Error]),
         []
    end,
    case bucket_needs_compaction(VbNames, Config) of
    false ->
        maybe_compact_views(BucketName, DDocNames, Config);
    true ->
        lists:foreach(fun(N) ->
            compact_vbucket(N, Config) end,
            VbNames)
    end.


bucket_needs_compaction(VbNames, Config) ->
    NumVbs = length(VbNames),
    SampleVbs = lists:map(
        fun(_) ->
             {I, _} = random:uniform_s(NumVbs, now()),
             lists:nth(I, VbNames)
        end,
        lists:seq(1, erlang:min(?NUM_SAMPLE_VBUCKETS, NumVbs))),
    % Don't care about duplicates.
    vbuckets_need_compaction(lists:usort(SampleVbs), Config, true).


vbuckets_need_compaction([], _Config, Acc) ->
    Acc;
vbuckets_need_compaction(_DbNames, _Config, false) ->
    false;
vbuckets_need_compaction([DbName | Rest], Config, Acc) ->
    case (catch couch_db:open_int(DbName, [])) of
    {ok, Db} ->
        Acc2 = Acc andalso can_db_compact(Config, Db),
        couch_db:close(Db),
        vbuckets_need_compaction(Rest, Config, Acc2);
    Error ->
        ?log_error("Couldn't open vbucket database `~s`: ~p", [DbName, Error]),
        false
    end.


compact_vbucket(DbName, Config) ->
    case (catch couch_db:open_int(DbName, [])) of
    {ok, Db} ->
        {ok, DbCompactPid} = couch_db:start_compact(Db),
        TimeLeft = compact_time_left(Config),
        DbMonRef = erlang:monitor(process, DbCompactPid),
        receive
        {'DOWN', DbMonRef, process, _, normal} ->
            couch_db:close(Db);
        {'DOWN', DbMonRef, process, _, Reason} ->
            couch_db:close(Db),
            ?log_error("Compaction daemon - an error occurred while"
                " compacting the database `~s`: ~p", [DbName, Reason])
        after TimeLeft ->
            ?log_info("Compaction daemon - canceling compaction for database"
                " `~s` because it's exceeding the allowed period.", [DbName]),
            erlang:demonitor(DbMonRef, [flush]),
            ok = couch_db:cancel_compact(Db),
            couch_db:close(Db)
        end;
    Error ->
        ?log_error("Couldn't open vbucket database `~s`: ~p", [DbName, Error])
    end.


maybe_compact_views(_BucketName, [], _Config) ->
    ok;
maybe_compact_views(BucketName, [DDocName | Rest], Config) ->
    case maybe_compact_view(BucketName, DDocName, Config) of
    ok ->
        maybe_compact_views(BucketName, Rest, Config);
    timeout ->
        ok
    end.


db_ddoc_names(Db) ->
    {ok, _, DDocNames} = couch_db:enum_docs(
        Db,
        fun(#doc_info{id = <<"_design/", _/binary>>, deleted = true}, _, Acc) ->
            {ok, Acc};
        (#doc_info{id = <<"_design/", _/binary>> = Id}, _, Acc) ->
            {ok, [Id | Acc]};
        (_, _, Acc) ->
            {stop, Acc}
        end, [], [{start_key, <<"_design/">>}, {end_key_gt, <<"_design0">>}]),
    DDocNames.


maybe_compact_view(BucketName, DDocId, Config) ->
    try couch_set_view:get_group_info(BucketName, DDocId) of
    {ok, GroupInfo} ->
        case can_view_compact(Config, BucketName, DDocId, GroupInfo) of
        true ->
            case compact_view_group(BucketName, DDocId, main, Config) of
            timeout ->
                timeout;
            ok ->
                maybe_compact_replica_group(Config, BucketName, DDocId, GroupInfo)
            end;
        false ->
            maybe_compact_replica_group(Config, BucketName, DDocId, GroupInfo)
        end
    catch T:E ->
        ?log_error("Error opening view group `~s` from bucket `~s`: ~p~n~p",
            [DDocId, BucketName, {T,E}, erlang:get_stacktrace()]),
        ok
    end.


maybe_compact_replica_group(Config, BucketName, DDocId, GroupInfo) ->
    case couch_util:get_value(replica_group_info, GroupInfo) of
    {RepGroupInfo} ->
        case can_view_compact(Config, BucketName, DDocId, RepGroupInfo) of
        true ->
            compact_view_group(BucketName, DDocId, replica, Config);
        false ->
            ok
        end;
    undefined ->
        ok
    end.


compact_view_group(BucketName, DDocId, Type, Config) ->
    {ok, CompactPid} = couch_set_view_compactor:start_compact(BucketName, DDocId, Type),
    TimeLeft = compact_time_left(Config),
    MonRef = erlang:monitor(process, CompactPid),
    receive
    {'DOWN', MonRef, process, CompactPid, normal} ->
        ok;
    {'DOWN', MonRef, process, CompactPid, Reason} ->
        ?log_error("Compaction daemon - an error ocurred while compacting"
            " the ~s view group `~s` from bucket `~s`: ~p",
             [Type, DDocId, BucketName, Reason]),
        ok
    after TimeLeft ->
        ?log_info("Compaction daemon - canceling the compaction for the "
            "~s view group `~s` of the bucket `~s` because it's exceeding"
            " the allowed period.", [Type, DDocId, BucketName]),
        erlang:demonitor(MonRef, [flush]),
        ok = couch_set_view_compactor:cancel_compact(BucketName, DDocId, Type),
        timeout
    end.


compact_time_left(#config{cancel = false}) ->
    infinity;
compact_time_left(#config{period = nil}) ->
    infinity;
compact_time_left(#config{period = #period{to = {ToH, ToM} = To}}) ->
    {H, M, _} = time(),
    case To > {H, M} of
    true ->
        ((ToH - H) * 60 * 60 * 1000) + (abs(ToM - M) * 60 * 1000);
    false ->
        ((24 - H + ToH) * 60 * 60 * 1000) + (abs(ToM - M) * 60 * 1000)
    end.


bucket_compact_config(BucketName) ->
    case ets:lookup(?CONFIG_ETS, BucketName) of
    [] ->
        case ets:lookup(?CONFIG_ETS, <<"_default">>) of
        [] ->
            nil;
        [{<<"_default">>, Config}] ->
            {ok, Config}
        end;
    [{BucketName, Config}] ->
        {ok, Config}
    end.


can_db_compact(#config{db_frag = Threshold} = Config, Db) ->
    case check_period(Config) of
    false ->
        false;
    true ->
        {ok, DbInfo} = couch_db:get_db_info(Db),
        {Frag, SpaceRequired} = frag(DbInfo),
        ?log_debug("Fragmentation for database `~s` is ~p%, estimated space for"
           " compaction is ~p bytes.", [Db#db.name, Frag, SpaceRequired]),
        case check_frag(Threshold, Frag) of
        false ->
            false;
        true ->
            Free = free_space(couch_config:get("couchdb", "database_dir")),
            case Free >= SpaceRequired of
            true ->
                true;
            false ->
                ?log_info("Compaction daemon - skipping database `~s` "
                    "compaction: the estimated necessary disk space is about ~p"
                    " bytes but the currently available disk space is ~p bytes.",
                   [Db#db.name, SpaceRequired, Free]),
                false
            end
        end
    end.

can_view_compact(Config, BucketName, DDocId, GroupInfo) ->
    case check_period(Config) of
    false ->
        false;
    true ->
        case couch_util:get_value(updater_running, GroupInfo) of
        true ->
            false;
        false ->
            {Frag, SpaceRequired} = frag(GroupInfo),
            ?log_debug("Fragmentation for view group `~s` (bucket `~s`) is "
                "~p%, estimated space for compaction is ~p bytes.",
                [DDocId, BucketName, Frag, SpaceRequired]),
            case check_frag(Config#config.view_frag, Frag) of
            false ->
                false;
            true ->
                Free = free_space(couch_config:get("couchdb", "view_index_dir")),
                case Free >= SpaceRequired of
                true ->
                    true;
                false ->
                    ?log_info("Compaction daemon - skipping view group `~s` "
                        "compaction (bucket `~s`): the estimated necessary "
                        "disk space is about ~p bytes but the currently available"
                        " disk space is ~p bytes.",
                        [DDocId, BucketName, SpaceRequired, Free]),
                    false
                end
            end
        end
    end.


check_period(#config{period = nil}) ->
    true;
check_period(#config{period = #period{from = From, to = To}}) ->
    {HH, MM, _} = erlang:time(),
    case From < To of
    true ->
        ({HH, MM} >= From) andalso ({HH, MM} < To);
    false ->
        ({HH, MM} >= From) orelse ({HH, MM} < To)
    end.


check_frag(nil, _) ->
    false;
check_frag(Threshold, Frag) ->
    Frag >= Threshold.


frag(Props) ->
    FileSize = couch_util:get_value(disk_size, Props),
    MinFileSize = list_to_integer(
        couch_config:get("compaction_daemon", "min_file_size", "131072")),
    case FileSize < MinFileSize of
    true ->
        {0, FileSize};
    false ->
        case couch_util:get_value(data_size, Props) of
        null ->
            {100, FileSize};
        0 ->
            {0, FileSize};
        DataSize ->
            Frag = round(((FileSize - DataSize) / FileSize * 100)),
            {Frag, space_required(DataSize)}
        end
    end.

% Rough, and pessimistic, estimation of necessary disk space to compact a
% database or view index.
space_required(DataSize) ->
    round(DataSize * 2.0).


load_config() ->
    lists:foreach(
        fun({DbName, ConfigString}) ->
            case parse_config(DbName, ConfigString) of
            {ok, Config} ->
                true = ets:insert(?CONFIG_ETS, {?l2b(DbName), Config});
            error ->
                ok
            end
        end,
        couch_config:get("compactions")).

parse_config(DbName, ConfigString) ->
    case (catch do_parse_config(ConfigString)) of
    {ok, Conf} ->
        {ok, Conf};
    incomplete_period ->
        ?log_error("Incomplete period ('to' or 'from' missing) in the compaction"
            " configuration for database `~s`", [DbName]),
        error;
    _ ->
        ?log_error("Invalid compaction configuration for database "
            "`~s`: `~s`", [DbName, ConfigString]),
        error
    end.

do_parse_config(ConfigString) ->
    {ok, ConfProps} = couch_util:parse_term(ConfigString),
    {ok, #config{period = Period} = Conf} = config_record(ConfProps, #config{}),
    case Period of
    nil ->
        {ok, Conf};
    #period{from = From, to = To} when From =/= nil, To =/= nil ->
        {ok, Conf};
    #period{} ->
        incomplete_period
    end.

config_record([], Config) ->
    {ok, Config};

config_record([{db_fragmentation, V} | Rest], Config) ->
    [Frag] = string:tokens(V, "%"),
    config_record(Rest, Config#config{db_frag = list_to_integer(Frag)});

config_record([{view_fragmentation, V} | Rest], Config) ->
    [Frag] = string:tokens(V, "%"),
    config_record(Rest, Config#config{view_frag = list_to_integer(Frag)});

config_record([{from, V} | Rest], #config{period = Period0} = Config) ->
    Time = parse_time(V),
    Period = case Period0 of
    nil ->
        #period{from = Time};
    #period{} ->
        Period0#period{from = Time}
    end,
    config_record(Rest, Config#config{period = Period});

config_record([{to, V} | Rest], #config{period = Period0} = Config) ->
    Time = parse_time(V),
    Period = case Period0 of
    nil ->
        #period{to = Time};
    #period{} ->
        Period0#period{to = Time}
    end,
    config_record(Rest, Config#config{period = Period});

config_record([{strict_window, true} | Rest], Config) ->
    config_record(Rest, Config#config{cancel = true});

config_record([{strict_window, false} | Rest], Config) ->
    config_record(Rest, Config#config{cancel = false});

config_record([{parallel_view_compaction, true} | Rest], Config) ->
    config_record(Rest, Config#config{parallel_view_compact = true});

config_record([{parallel_view_compaction, false} | Rest], Config) ->
    config_record(Rest, Config#config{parallel_view_compact = false}).


parse_time(String) ->
    [HH, MM] = string:tokens(String, ":"),
    {list_to_integer(HH), list_to_integer(MM)}.


free_space(Path) ->
    DiskData = lists:sort(
        fun({PathA, _, _}, {PathB, _, _}) ->
            length(filename:split(PathA)) > length(filename:split(PathB))
        end,
        disksup:get_disk_data()),
    free_space_rec(abs_path(Path), DiskData).

free_space_rec(_Path, []) ->
    undefined;
free_space_rec(Path, [{MountPoint0, Total, Usage} | Rest]) ->
    MountPoint = abs_path(MountPoint0),
    case MountPoint =:= string:substr(Path, 1, length(MountPoint)) of
    false ->
        free_space_rec(Path, Rest);
    true ->
        trunc(Total - (Total * (Usage / 100))) * 1024
    end.

abs_path(Path0) ->
    Path = filename:absname(Path0),
    case lists:last(Path) of
    $/ ->
        Path;
    _ ->
        Path ++ "/"
    end.
