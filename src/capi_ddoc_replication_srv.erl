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

%% Maintains design document replication between the <BucketName>/master
%% vbuckets (CouchDB databases) of all cluster nodes.

-module(capi_ddoc_replication_srv).
-include("couch_db.hrl").
-include("ns_common.hrl").

-export([start_link/1, update_doc/2, force_update/1,
         foreach_doc/2, fetch_ddoc_ids/1,
         full_live_ddocs/1,
         sorted_full_live_ddocs/1,
         foreach_live_ddoc_id/2]).

-behaviour(cb_generic_replication_srv).
-export([server_name/1, init/1, get_remote_nodes/1,
         load_local_docs/2, open_local_db/1]).

-record(state, {bucket, master}).


update_doc(Bucket, Doc) ->
    gen_server:call(server_name(Bucket),
                    {interactive_update, Doc}, infinity).

-spec fetch_ddoc_ids(bucket_name() | binary()) -> [binary()].
fetch_ddoc_ids(Bucket) ->
    Pairs = foreach_live_ddoc_id(Bucket, fun (_) -> ok end),
    erlang:element(1, lists:unzip(Pairs)).

force_update(Bucket) ->
    cb_generic_replication_srv:force_update(server_name(Bucket)).

-spec foreach_live_ddoc_id(bucket_name() | binary(),
                           fun ((binary()) -> any())) -> [{binary(), any()}].
foreach_live_ddoc_id(Bucket, Fun) ->
    Ref = make_ref(),
    RVs = foreach_doc(
            Bucket,
            fun (Doc) ->
                    case Doc of
                        #doc{deleted = true} ->
                            Ref;
                        _ ->
                            Fun(Doc#doc.id)
                    end
            end),
    [Pair || {_Id, V} = Pair <- RVs,
             V =/= Ref].

full_live_ddocs(Bucket) ->
    Ref = make_ref(),
    RVs = foreach_doc(
            Bucket,
            fun (Doc) ->
                    case Doc of
                        #doc{deleted = true} ->
                            Ref;
                        _ ->
                            Doc
                    end
            end),
    [V || {_Id, V} <- RVs,
          V =/= Ref].

sorted_full_live_ddocs(Bucket) ->
    lists:keysort(#doc.id, full_live_ddocs(Bucket)).

-spec foreach_doc(bucket_name() | binary(),
                   fun ((#doc{}) -> any())) -> [{binary(), any()}].
foreach_doc(Bucket, Fun) ->
    cb_generic_replication_srv:foreach_doc(server_name(Bucket), Fun).


start_link(Bucket) ->
    cb_generic_replication_srv:start_link(?MODULE, Bucket).


%% Callbacks
server_name(Bucket) when is_binary(Bucket) ->
    server_name(?b2l(Bucket));
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).


init(Bucket) ->
    Self = self(),
    MasterVBucket = ?l2b(Bucket ++ "/" ++ "master"),
    %% Update myself whenever the config changes (rebalance)
    ns_pubsub:subscribe_link(
      ns_config_events,
      fun (_, _) -> cb_generic_replication_srv:force_update(Self) end,
      empty),

    {ok, #state{bucket=Bucket, master=MasterVBucket}}.


get_remote_nodes(#state{bucket=Bucket}) ->
    case ns_bucket:get_bucket(Bucket) of
        {ok, Conf} ->
            Self = node(),
            proplists:get_value(servers, Conf) -- [Self];
        not_present ->
            []
    end.


load_local_docs(Db, _State) ->
    couch_db:get_design_docs(Db, deleted_also).


open_local_db(#state{master=MasterVBucket}) ->
    case couch_db:open(MasterVBucket, []) of
        {ok, Db} ->
            {ok, Db};
        {not_found, _} ->
            couch_db:create(MasterVBucket, [])
    end.
