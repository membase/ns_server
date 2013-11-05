-module(single_bucket_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([start_link/1, init/1]).


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
    [{{capi_set_view_manager, BucketName},
      {capi_set_view_manager, start_link, [BucketName]},
      permanent, 1000, worker, [capi_set_view_manager]},
     {{ns_memcached, BucketName}, {ns_memcached, start_link, [BucketName]},
      %% sometimes bucket deletion is slow. NOTE: we're not deleting
      %% bucket on system shutdown anymore
      permanent, 86400000, worker, [ns_memcached]},
     {{replication_manager, BucketName}, {replication_manager, start_link, [BucketName]},
      permanent, 1000, worker, []},
     {{ns_vbm_sup, BucketName}, {ns_vbm_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [ns_vbm_sup]},
     {{upr_sup, BucketName}, {upr_sup, start_link, [BucketName]},
      permanent, infinity, supervisor, [upr_sup]},
     {{janitor_agent, BucketName}, {janitor_agent, start_link, [BucketName]},
      permanent, brutal_kill, worker, []},
     {{couch_stats_reader, BucketName},
      {couch_stats_reader, start_link, [BucketName]},
      permanent, 1000, worker, [couch_stats_reader]},
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
