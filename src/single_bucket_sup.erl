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
    [{{capi_ddoc_replication_srv, BucketName},
      {capi_ddoc_replication_srv, start_link, [BucketName]},
      permanent, 1000, worker, [capi_ddoc_replication_srv]},
     {{ns_memcached_sup, BucketName},
      {ns_memcached_sup, start_link, [BucketName]},
      %% ns_memcached can take a long time to terminate; but it will do it in
      %% a finite amount of time since all the shutdown timeouts in
      %% ns_memcached_sup are finite
      permanent, infinity, supervisor, [ns_memcached_sup]}].

init([BucketName]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs(BucketName)}}.
