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


-export([start_link/1, update_doc/2,
         proxy_server_name/1,
         foreach_doc/2, fetch_ddoc_ids/1,
         full_live_ddocs/1,
         sorted_full_live_ddocs/1,
         foreach_live_ddoc_id/2]).

update_doc(Bucket, Doc) ->
    gen_server:call(capi_set_view_manager:server(Bucket),
                    {interactive_update, Doc}, infinity).

-spec fetch_ddoc_ids(bucket_name() | binary()) -> [binary()].
fetch_ddoc_ids(Bucket) ->
    Pairs = foreach_live_ddoc_id(Bucket, fun (_) -> ok end),
    erlang:element(1, lists:unzip(Pairs)).

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

%% C-release is using this server name for ddoc replication. So it's
%% better if we don't break backwards compat with it. This process
%% merely forwards casts to capi_set_view_manager
start_link(Bucket) ->
    proc_lib:start_link(erlang, apply, [fun start_proxy_loop/1, [Bucket]]).

start_proxy_loop(Bucket) ->
    SetViewMgr = erlang:whereis(capi_set_view_manager:server(Bucket)),
    erlang:link(SetViewMgr),
    erlang:register(proxy_server_name(Bucket), self()),
    proc_lib:init_ack({ok, self()}),
    proxy_loop(SetViewMgr).

proxy_loop(SetViewMgr) ->
    receive
        Msg ->
            SetViewMgr ! Msg,
            proxy_loop(SetViewMgr)
    end.

proxy_server_name(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

-spec foreach_doc(bucket_name() | binary(),
                   fun ((#doc{}) -> any())) -> [{binary(), any()}].
foreach_doc(Bucket, Fun) ->
    gen_server:call(capi_set_view_manager:server(Bucket), {foreach_doc, Fun}, infinity).

