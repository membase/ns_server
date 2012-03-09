%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(couch_stats_reader).

-include("couch_db.hrl").
-include("ns_common.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1, fetch_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bucket, stats = []}).

%% Amount of time to wait between fetching stats
-define(SAMPLE_RATE, 5000).


start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).

init(Bucket) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:bucket_type(BucketConfig) of
        membase -> start_timer();
        memcached -> ok
    end,
    {ok, #state{bucket=Bucket}}.

handle_call(fetch_stats, _From, State) ->
    {reply, State#state.stats, State};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(check_alerts, #state{bucket = Bucket} = State) ->
    {noreply, State#state{stats = grab_couch_stats(Bucket)}};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


start_timer() ->
    timer:send_interval(?SAMPLE_RATE, check_alerts).

server(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).

fetch_stats(Bucket) ->
    Stats = gen_server:call({server(Bucket), node()}, fetch_stats),
    [{iolist_to_binary([<<"couch_">>, atom_to_list(Key)]), ?l2b(?i2l(Val))}
     || {Key, Val} <- Stats].

-spec grab_couch_stats(string()) -> list().
grab_couch_stats(Bucket) ->

    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    VBuckets = ns_bucket:all_node_vbuckets(Conf),

    GetStats = fun(List) ->
                       {proplists:get_value(disk_size, List),
                        proplists:get_value(data_size, List)}
               end,

    DBStats = fun(Id, {DiskSize, DataSize}) ->
                      VBucket = iolist_to_binary([Bucket, <<"/">>, ?i2l(Id)]),
                      case couch_db:open(VBucket, []) of
                          {ok, Db} ->
                              try
                                  {ok, Info} = couch_db:get_db_info(Db),
                                  {BucketDisk, BucketData} = GetStats(Info),
                                  {DiskSize + BucketDisk,
                                   DataSize + BucketData}
                              after
                                  ok = couch_db:close(Db)
                              end;
                          _ ->
                              {DiskSize, DataSize}
                      end
              end,

    ViewStats = fun(Id, {DiskSize, DataSize}) ->
                        {ok, Info} = couch_set_view:get_group_info(?l2b(Bucket), Id),
                        Group = proplists:get_value(replica_group_info, Info, false),
                        {ViewDisk, ViewData} = GetStats(Info),
                        {RDisk, RData} = case Group of
                                             false -> {0, 0};
                                             {Replica} -> GetStats(Replica)
                                         end,
                        {DiskSize + ViewDisk + RDisk,
                         DataSize + ViewData + RData}
                end,

    CouchDir = couch_config:get("couchdb", "database_dir"),
    ViewRoot = couch_config:get("couchdb", "view_index_dir"),

    DocsActualDiskSize = misc:dir_size(filename:join([CouchDir, Bucket])),
    ViewsActualDiskSize = misc:dir_size(couch_set_view:set_index_dir(ViewRoot, ?l2b(Bucket))),

    {ok, DDocs} = capi_set_view_manager:fetch_ddocs(Bucket),

    {DocsDiskSize, DocsDataSize} = lists:foldl(DBStats, {0, 0}, VBuckets),
    {ViewsDiskSize, ViewsDataSize} =
        lists:foldl(ViewStats, {0, 0}, sets:to_list(DDocs)),

    [{docs_actual_disk_size, DocsActualDiskSize},
     {views_actual_disk_size, ViewsActualDiskSize},
     {docs_data_size, DocsDataSize},
     {views_data_size, ViewsDataSize},
     {docs_disk_size, DocsDiskSize},
     {views_disk_size, ViewsDiskSize}].
