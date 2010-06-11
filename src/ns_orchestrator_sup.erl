%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Make sure there is an orchestrator running for each bucket
%% This needs to be running once per cluster

-module(ns_orchestrator_sup).

-behaviour(supervisor).

-define(SERVER, {global, ?MODULE}).

-define(CHECK_INTERVAL, 5000).

-export([start_link/0]).

-export([init/1]).

-export([check/0]).

start_link() ->
    supervisor:start_link(?SERVER, ?MODULE, []).

init([]) ->
    {ok, _Tref} = timer:apply_interval(?CHECK_INTERVAL, ?MODULE, check, []),
    {ok, {{simple_one_for_one, 3, 10},
          [{ignored, {ns_orchestrator, start_link, []},
           transient, 10, worker, [ns_orchestrator]}]}}.

%% Called by the timer periodically
check() ->
    lists:foreach(fun (Bucket) ->
                          case supervisor:start_child(?SERVER, [Bucket]) of
                              {ok, Pid} ->
                                  error_logger:info_msg("~p:check(): started orchestrator for ~s as ~p~n",
                                                        [?MODULE, Bucket, Pid]);
                              {error, {already_started, _Pid}} -> ok;
                              Error ->
                                  error_logger:error_msg("~p:check(): error starting child for ~s: ~p~n",
                                                        [?MODULE, Bucket, Error])
                          end
                  end, ns_bucket:get_bucket_names()).
