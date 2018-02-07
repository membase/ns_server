%% @author Couchbase <info@couchbase.com>
%% @copyright 2014-2015 Couchbase, Inc.
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
%% @doc this module contains the implementation for some operations with
%%      _replicator documents
%%

-module(xdc_rdoc_api).
-include("couch_db.hrl").
-include("ns_common.hrl").

-export([update_doc/1,
         delete_replicator_doc/1,
         get_full_replicator_doc/1]).

update_doc(Doc) ->
    ns_couchdb_api:update_doc(xdcr, Doc).

-spec delete_replicator_doc(string()) -> ok | not_found.
delete_replicator_doc(XID) ->
    case do_delete_replicator_doc(XID) of
        {ok, OldDoc} ->
            Source = misc:expect_prop_value(source, OldDoc),
            Target = misc:expect_prop_value(target, OldDoc),

            {ok, {UUID, BucketName}} = remote_clusters_info:parse_remote_bucket_reference(Target),
            ClusterName =
                case remote_clusters_info:find_cluster_by_uuid(UUID) of
                    not_found ->
                        "\"unknown\"";
                    Cluster ->
                        case proplists:get_value(deleted, Cluster, false) of
                            false ->
                                io_lib:format("\"~s\"", [misc:expect_prop_value(name, Cluster)]);
                            true ->
                                io_lib:format("at ~s", [misc:expect_prop_value(hostname, Cluster)])
                        end
                end,

            ale:info(?USER_LOGGER,
                     "Replication from bucket \"~s\" to bucket \"~s\" on cluster ~s removed.",
                     [Source, BucketName, ClusterName]),
            ok;
        not_found ->
            not_found
    end.

-spec do_delete_replicator_doc(string()) -> {ok, list()} | not_found.
do_delete_replicator_doc(IdList) ->
    Id = erlang:list_to_binary(IdList),
    Docs = goxdcr_rest:find_all_replication_docs(),
    MaybeDoc = [Doc || [{id, CandId} | _] = Doc <- Docs,
                       CandId =:= Id],
    case MaybeDoc of
        [] ->
            not_found;
        [Doc] ->
            NewDoc = couch_doc:from_json_obj(
                       {[{<<"meta">>,
                          {[{<<"id">>, Id}, {<<"deleted">>, true}]}}]}),
            ok = update_doc(NewDoc),
            {ok, Doc}
    end.

-spec get_full_replicator_doc(string() | binary()) -> {ok, #doc{}} | not_found.
get_full_replicator_doc(Id) when is_list(Id) ->
    get_full_replicator_doc(list_to_binary(Id));
get_full_replicator_doc(Id) when is_binary(Id) ->
    case ns_couchdb_api:get_doc(xdcr, Id) of
        {not_found, _} ->
            not_found;
        {ok, #doc{body={Props0}} = Doc} ->
            Props = [{couch_util:to_binary(K), V} || {K, V} <- Props0],
            {ok, Doc#doc{body={Props}}}
    end.
