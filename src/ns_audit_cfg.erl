%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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
%% @doc server for maintaining audit configuration file
%%
-module(ns_audit_cfg).

-behaviour(gen_server).

-include("ns_common.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([start_link/0, get_global/0, set_global/1, default_audit_json_path/0, get_log_path/0]).

string_key(log_path) ->
    true;
string_key(descriptors_path) ->
    true;
string_key(_) ->
    false.

key_api_to_config(auditdEnabled) ->
    auditd_enabled;
key_api_to_config(rotateInterval) ->
    rotate_interval;
key_api_to_config(rotateSize) ->
    rotate_size;
key_api_to_config(logPath) ->
    log_path.

key_config_to_api(auditd_enabled) ->
    auditdEnabled;
key_config_to_api(rotate_interval) ->
    rotateInterval;
key_config_to_api(rotate_size) ->
    rotateSize;
key_config_to_api(log_path) ->
    logPath;
key_config_to_api(_) ->
    undefined.

is_notable_config_key(audit) ->
    true;
is_notable_config_key({node, N, audit}) ->
    N =:= node();
is_notable_config_key(_) ->
    false.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

get_global() ->
    gen_server:call(?MODULE, get_global).

set_global(KVList) ->
    ns_config:set_sub(audit, [{key_api_to_config(ApiK), V} || {ApiK, V} <- KVList]).

init([]) ->
    {Global, Local} = read_config(),

    Self = self(),
    ns_pubsub:subscribe_link(ns_config_events,
                             fun ({Key, _}) ->
                                     case is_notable_config_key(Key) of
                                         true ->
                                             Self ! update_audit_json;
                                         _ ->
                                             []
                                     end;
                                 (_Other) ->
                                     []
                             end),

    write_audit_json(lists:ukeymerge(1, Local, Global)),
    {ok, {Global, Local}}.

handle_call(get_global, _From, {Global, _Local} = State) ->
    {reply, lists:foldl(fun ({K, V}, Acc) ->
                                case key_config_to_api(K) of
                                    undefined ->
                                        Acc;
                                    ApiK ->
                                        [{ApiK, V} | Acc]
                                end
                        end, [], Global), State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(notify_memcached, State) ->
    misc:flush(notify_memcached),
    ?log_debug("Instruct memcached to reload audit config"),
    ok = ns_memcached_sockets_pool:executing_on_socket(
           fun (Sock) ->
                   mc_client_binary:audit_config_reload(Sock)
           end),
    {noreply, State};

handle_info(update_audit_json, {OldGlobal, OldLocal}) ->
    misc:flush(update_audit_json),
    {Global, Local} = read_config(),
    Merged = lists:ukeymerge(1, Local, Global),
    case lists:ukeymerge(1, OldLocal, OldGlobal) of
        Merged ->
            ok;
        _ ->
            write_audit_json(Merged)
    end,
    {noreply, {Global, Local}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

default_audit_json_path() ->
    filename:join(path_config:component_path(data, "config"), "audit.json").

audit_json_path() ->
    ns_config:search_node_prop(ns_config:latest(), memcached, audit_file).

is_enabled() ->
    ns_config:search_node_prop(ns_config:latest(), audit, auditd_enabled, false).

get_log_path() ->
    case is_enabled() of
        false ->
            undefined;
        true ->
            case ns_config:search_node_prop(ns_config:latest(), audit, log_path) of
                undefined ->
                    undefined;
                Path ->
                    {ok, misc:absname(Path)}
            end
    end.

write_audit_json(Params) ->
    Path = audit_json_path(),
    CompleteParams = Params ++ [{version, 1},
                                {descriptors_path, path_config:component_path(sec)}],
    ?log_debug("Writing new content to ~p : ~p", [Path, CompleteParams]),
    Json = lists:map(fun({K, V}) ->
                             {K, case string_key(K) of
                                     true ->
                                         list_to_binary(V);
                                     false ->
                                         V
                                 end}
                     end, CompleteParams),
    Bytes = ejson:encode({Json}),
    ok = misc:atomic_write_file(Path, Bytes),
    self() ! notify_memcached.

read_config() ->
    {case ns_config:search(audit) of
         {value, V} ->
             lists:keysort(1, V);
         false ->
             []
     end,
     case ns_config:search({node, node(), audit}) of
         {value, V} ->
             lists:keysort(1, V);
         false ->
             []
     end}.
