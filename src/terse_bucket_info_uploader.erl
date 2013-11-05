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
%%
%% @doc This service watches changes of terse bucket info and uploads
%% it to ep-engine
-module(terse_bucket_info_uploader).
-include("ns_common.hrl").

-export([start_link/1]).

start_link(BucketName) ->
    case ns_bucket:get_bucket(BucketName) of
        not_present ->
            ignore;
        {ok, BucketConfig} ->
            case proplists:get_value(type, BucketConfig) of
                memcached ->
                    ignore;
                _ ->
                    Name = list_to_atom("terse_bucket_info_uploader-" ++ BucketName),
                    work_queue:start_link(Name, fun () -> init(BucketName) end)
            end
    end.

init(BucketName) ->
    Self = self(),
    ns_pubsub:subscribe_link(bucket_info_cache_invalidations, fun invalidation_loop/2, {BucketName, Self}),
    submit_refresh(BucketName, Self).

refresh_cluster_config(BucketName) ->
    case bucket_info_cache:terse_bucket_info(BucketName) of
        {ok, JSON} ->
            ns_memcached:set_cluster_config(BucketName, JSON);
        not_present ->
            ?log_debug("Bucket ~s is dead", [BucketName]),
            ok;
        {T, E, Stack} = Exception ->
            ?log_error("Got exception trying to get terse bucket info: ~p", [Exception]),
            timer:sleep(10000),
            erlang:raise(T, E, Stack)
    end.

submit_refresh(BucketName, Process) ->
    work_queue:submit_work(Process,
                           fun () ->
                                   refresh_cluster_config(BucketName)
                           end).

invalidation_loop(BucketName, {BucketName, Parent}) ->
    submit_refresh(BucketName, Parent),
    {BucketName, Parent};
invalidation_loop('*', {BucketName, Parent}) ->
    submit_refresh(BucketName, Parent),
    {BucketName, Parent};
invalidation_loop(_, State) ->
    State.
