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

-include("ns_common.hrl").

-behaviour(gen_server).

%% API
-export([start_link/1, fetch_stats/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bucket, stats = dict:new()}).

%% Amount of time to wait between fetching stats
-define(SAMPLE_RATE, 3000).


start_link(Bucket) ->
    gen_server:start_link({local, server(Bucket)}, ?MODULE, Bucket, []).

init(Bucket) ->
    start_timer(),
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
    Dict = gen_server:call({server(Bucket), node()}, fetch_stats),
    [{<<"couch_disk_size">>, i2b(misc:dict_get(disk_size, Dict, 0))},
     {<<"couch_data_size">>, i2b(misc:dict_get(data_size, Dict, 0))}].


-spec grab_couch_stats(string()) -> list().
grab_couch_stats(Bucket) ->

    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    VBuckets = ns_bucket:all_node_vbuckets(Conf),

    Count = fun(Id, Dict) ->
                    VBucket = lists:flatten(io_lib:format("~s/~p", [Bucket, Id])),
                    case couch_db:open(list_to_binary(VBucket), []) of
                        {ok, Db} ->
                            try
                                {ok, Info} = couch_db:get_db_info(Db),
                                DiskSize = proplists:get_value(disk_size, Info),
                                DataSize = proplists:get_value(data_size, Info),
                                Tmp = dict:update_counter(data_size, DataSize, Dict),
                                dict:update_counter(disk_size, DiskSize, Tmp)
                            after
                                ok = couch_db:close(Db)
                            end;
                        _ ->
                            Dict
                    end
            end,

    lists:foldl(Count, dict:new(), VBuckets).

-spec i2b(integer()) -> binary().
i2b(I) ->
    list_to_binary(integer_to_list(I)).
