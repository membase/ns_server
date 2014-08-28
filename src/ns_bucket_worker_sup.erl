%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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

-module(ns_bucket_worker_sup).

-behaviour(supervisor).

-export([start_link/1]).
-export([init/1]).

start_link(SingleBucketSup) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [SingleBucketSup]).

init([SingleBucketSup]) ->
    {ok, {{one_for_all, 3, 10}, child_specs(SingleBucketSup)}}.

child_specs(SingleBucketSup) ->
    [{ns_bucket_worker, {work_queue, start_link, [ns_bucket_worker]},
      permanent, 1000, worker, [work_queue]},
     {ns_bucket_sup, {ns_bucket_sup, start_link, [SingleBucketSup]},
      permanent, infinity, supervisor, [ns_bucket_sup]}].
