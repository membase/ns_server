-module(single_bucket_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([start_link/1, init/1,
         ignore_if_not_couchbase_bucket/2]).


start_link(BucketName) ->
    ParentPid = self(),
    {ok, erlang:spawn_link(
           fun () ->
                   erlang:process_flag(trap_exit, true),
                   Name = list_to_atom(atom_to_list(?MODULE) ++ "-" ++ BucketName),
                   {ok, Pid} = supervisor:start_link({local, Name},
                                                     ?MODULE, [BucketName]),
                   top_loop(ParentPid, Pid, BucketName)
           end)}.

top_loop(ParentPid, Pid, BucketName) ->
    receive
        {'EXIT', Pid, Reason} ->
            ?log_debug("per-bucket supervisor for ~p died with reason ~p~n",
                       [BucketName, Reason]),
            exit(Reason);
        {'EXIT', _, Reason} = X ->
            ?log_debug("Delegating exit ~p to child supervisor: ~p~n", [X, Pid]),
            exit(Pid, Reason),
            top_loop(ParentPid, Pid, BucketName);
        X ->
            ?log_debug("Delegating ~p to child supervisor: ~p~n", [X, Pid]),
            Pid ! X,
            top_loop(ParentPid, Pid, BucketName)
    end.

child_specs(BucketName) ->
    [{{doc_replicator, BucketName},
      {doc_replicator, start_link, [BucketName]},
      permanent, 1000, worker, [doc_replicator]},
     {{doc_replication_srv, BucketName},
      {doc_replication_srv, start_link, [BucketName]},
      permanent, 1000, worker, [doc_replication_srv]},
     {{ns_memcached, BucketName}, {ns_memcached, start_link, [BucketName]},
      %% sometimes bucket deletion is slow. NOTE: we're not deleting
      %% bucket on system shutdown anymore
      permanent, 86400000, worker, [ns_memcached]},
     {{ns_vbm_sup, BucketName}, {ns_vbm_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [ns_vbm_sup]},
     {{dcp_sup, BucketName}, {dcp_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [dcp_sup]},
     {{replication_manager, BucketName}, {replication_manager, start_link, [BucketName]},
      permanent, 1000, worker, []},
     {{dcp_notifier, BucketName}, {dcp_notifier, start_link, [BucketName]},
      permanent, 1000, worker, []},
     {{janitor_agent_sup, BucketName}, {janitor_agent_sup, start_link, [BucketName]},
      permanent, 10000, worker, [janitor_agent_sup]},
     {{stats_collector, BucketName}, {stats_collector, start_link, [BucketName]},
      permanent, 1000, worker, [stats_collector]},
     {{stats_archiver, BucketName}, {stats_archiver, start_link, [BucketName]},
      permanent, 1000, worker, [stats_archiver]},
     {{stats_reader, BucketName}, {stats_reader, start_link, [BucketName]},
      permanent, 1000, worker, [stats_reader]},
     {{failover_safeness_level, BucketName},
      {failover_safeness_level, start_link, [BucketName]},
      permanent, 1000, worker, [failover_safeness_level]},
     {{terse_bucket_info_uploader, BucketName},
      {terse_bucket_info_uploader, start_link, [BucketName]},
      permanent, 1000, worker, []}].

init([BucketName]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs(BucketName)}}.

ignore_if_not_couchbase_bucket(BucketName, Body) ->
    case ns_bucket:get_bucket(BucketName) of
        not_present ->
            ignore;
        {ok, BucketConfig} ->
            case proplists:get_value(type, BucketConfig) of
                memcached ->
                    ignore;
                _ ->
                    Body(BucketConfig)
            end
    end.
