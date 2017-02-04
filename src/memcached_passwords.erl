%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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
%% @doc handling of memcached passwords file
-module(memcached_passwords).

-behaviour(memcached_cfg).

-export([start_link/0, sync/0]).

%% callbacks
-export([format_status/1, init/0, filter_event/1, handle_event/2, producer/1, refresh/0]).

-include("ns_common.hrl").
-include("pipes.hrl").

-record(state, {buckets,
                admin_user,
                admin_pass}).

start_link() ->
    Path = ns_config:search_node_prop(ns_config:latest(), isasl, path),
    memcached_cfg:start_link(?MODULE, Path).

sync() ->
    memcached_cfg:sync(?MODULE).

format_status(State) ->
    Buckets = lists:map(fun ({U, _P}) ->
                                {U, "*****"}
                        end,
                        State#state.buckets),
    State#state{buckets=Buckets, admin_pass="*****"}.

init() ->
    Config = ns_config:get(),
    AU = ns_config:search_node_prop(Config, memcached, admin_user),
    AP = ns_config:search_node_prop(Config, memcached, admin_pass),
    Buckets = extract_creds(ns_config:search(Config, buckets, [])),

    #state{buckets = Buckets,
           admin_user = AU,
           admin_pass = AP}.

filter_event({buckets, _V}) ->
    true;
filter_event({auth_version, _V}) ->
    true;
filter_event(_) ->
    false.

handle_event({buckets, V}, #state{buckets = Buckets} = State) ->
    case extract_creds(V) of
        Buckets ->
            unchanged;
        NewBuckets ->
            {changed, State#state{buckets = NewBuckets}}
    end;
handle_event({auth_version, _V}, State) ->
    {changed, State}.

producer(State) ->
    case cluster_compat_mode:is_cluster_spock() of
        true ->
            make_producer(State);
        false ->
            ?make_producer(?yield(generate_45(State)))
    end.

generate_45(#state{buckets = Buckets,
                   admin_user = AU,
                   admin_pass = AP}) ->
    UserPasswords = [{AU, AP} | Buckets],
    Infos = menelaus_users:build_memcached_auth_info(UserPasswords),
    Json = {struct, [{<<"users">>, Infos}]},
    menelaus_util:encode_json(Json).

make_producer(#state{buckets = Buckets,
                     admin_user = AU,
                     admin_pass = AP}) ->
    pipes:compose([menelaus_users:select_auth_infos('_'),
                   jsonify_auth(AU, AP, Buckets),
                   sjson:encode_extended_json([{compact, false},
                                               {strict, false}])]).

jsonify_auth(AU, AP, Buckets) ->
    ?make_transducer(
       begin
           ?yield(object_start),
           ?yield({kv_start, <<"users">>}),
           ?yield(array_start),

           %% TODO: remove buckets after upgrade will be implemented
           AdminAndBuckets = menelaus_users:build_memcached_auth_info([{AU, AP} | Buckets]),
           lists:foreach(
             fun (AdminOrBucket) ->
                     ?yield({json, AdminOrBucket})
             end, AdminAndBuckets),

           pipes:foreach(
             ?producer(),
             fun ({{auth, _Identity}, Auth}) ->
                     case menelaus_users:get_memcached_auth(Auth) of
                         undefined ->
                             ok;
                         V ->
                             ?yield({json, V})
                     end
             end),
           ?yield(array_end),
           ?yield(kv_end),
           ?yield(object_end)
       end).

refresh() ->
    ns_memcached:connect_and_send_isasl_refresh().

extract_creds(ConfigList) ->
    Configs = proplists:get_value(configs, ConfigList),
    lists:sort([{BucketName,
                 proplists:get_value(sasl_password, BucketConfig, "")}
                || {BucketName, BucketConfig} <- Configs]).
