%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
