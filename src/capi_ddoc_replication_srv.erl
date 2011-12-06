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

-behaviour(cb_generic_replication_srv).

-include("couch_db.hrl").

-export([start_link/1, force_update/1]).
-export([server_name/1, init/1, local_url/1, remote_url/2, get_servers/1]).

-record(state, {bucket, master}).

start_link(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        memcached ->
            ignore;
        _ ->
            cb_generic_replication_srv:start_link(?MODULE, Bucket)
    end.

force_update(Bucket) ->
    cb_generic_replication_srv:force_update(?MODULE, Bucket).


%% Callbacks
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

init(Bucket) ->
    Self = self(),
    MasterVBucket = ?l2b(Bucket ++ "/" ++ "master"),

    case couch_db:open(MasterVBucket, []) of
        {ok, Db} ->
            couch_db:close(Db);
        {not_found, _} ->
            {ok, Db} = couch_db:create(MasterVBucket, []),
            couch_db:close(Db)
    end,

    % Update myself whenever the config changes (rebalance)
    ns_pubsub:subscribe(
      ns_config_events,
      fun (_, _) ->
              cb_generic_replication_srv:force_update(Self)
      end,
      empty),

    {ok, #state{bucket=Bucket, master=MasterVBucket}}.

local_url(#state{master=Master} = _State) ->
    Master.

remote_url(Node, #state{bucket=Bucket} = _State) ->
    Url = capi_utils:capi_url(Node, "/" ++ mochiweb_util:quote_plus(Bucket)
                              ++ "%2Fmaster", "127.0.0.1"),
    ?l2b(Url).

get_servers(#state{bucket=Bucket} = _State) ->
    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    Self = node(),

    proplists:get_value(servers, Conf) -- [Self].
