%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

%% Run an orchestrator and vbm supervisor per bucket

-module(ns_bucket_sup).

-behaviour(supervisor).

-export([start_link/1]).

-export ([notify/2]).

-export([init/1]).


%% API

start_link(Bucket) ->
    supervisor:start_link(?MODULE, [Bucket]).


notify(Bucket, BucketConfig) ->
    ns_orchestrator:notify(Bucket, BucketConfig).

init([Bucket]) ->
    {ok, {{one_for_all, 3, 10},
          [{ns_orchestrator, {ns_orchestrator, start_link, [Bucket]},
            permanent, 10, worker, [ns_orchestrator]}]}}.
