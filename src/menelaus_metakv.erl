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

-module(menelaus_metakv).

-export([handle_post/1]).

-include("ns_common.hrl").
-include("ns_config.hrl").

handle_post(Req) ->
    Params = Req:parse_post(),
    Method = proplists:get_value("method", Params),
    case Method of
        "get" ->
            handle_get_post(Req, Params);
        "set" ->
            handle_set_post(Req, Params);
        "delete" ->
            handle_delete_post(Req, Params);
        "iterate" ->
            handle_iterate_post(Req, Params)
    end.

handle_get_post(Req, Params) ->
    Path = list_to_binary(proplists:get_value("path", Params)),
    case ns_config:search_with_vclock(ns_config:get(), {metakv, Path}) of
        false ->
            menelaus_util:reply_json(Req, {[]});
        {value, Val0, VC} ->
            case Val0 =:= ?DELETED_MARKER of
                true ->
                    menelaus_util:reply_json(Req, {[]});
                false ->
                    Rev = base64:encode(erlang:term_to_binary(VC)),
                    Val = base64:encode(Val0),
                    menelaus_util:reply_json(Req, {[{rev, Rev},
                                                    {value, Val}]})
            end
    end.

get_old_vclock(Cfg, K) ->
    case ns_config:search_with_vclock(Cfg, K) of
        false ->
            missing;
        {value, OldV, OldVC} ->
            case OldV of
                ?DELETED_MARKER ->
                    missing;
                _ ->
                    OldVC
            end
    end.

handle_mutate(Req, Params, Value) ->
    Path = list_to_binary(proplists:get_value("path", Params)),
    Rev = case proplists:get_value("rev", Params) of
              undefined ->
                  case proplists:get_value("create", Params) of
                      undefined ->
                          undefined;
                      _ ->
                          missing
                  end;
              XRev ->
                  XRevB = list_to_binary(XRev),
                  binary_to_term(XRevB)
          end,
    K = {metakv, Path},
    RV = work_queue:submit_sync_work(
           menelaus_metakv_worker,
           fun () ->
                   ns_config:run_txn(
                     fun (Cfg, SetFn) ->
                             OldVC = get_old_vclock(Cfg, K),
                             case Rev =:= undefined orelse Rev =:= OldVC of
                                 true ->
                                     {commit, SetFn(K, Value, Cfg)};
                                 false ->
                                     {abort, mismatch}
                             end
                     end)
           end),
    case RV of
        {abort, mismatch} ->
            menelaus_util:reply(Req, 409);
        {commit, _} ->
            ?log_debug("updated ~s to hold ~s", [Path, Value]),
            menelaus_util:reply(Req, 200)
    end.

handle_set_post(Req, Params) ->
    Value = list_to_binary(proplists:get_value("value", Params)),
    handle_mutate(Req, Params, Value).

handle_delete_post(Req, Params) ->
    handle_mutate(Req, Params, ?DELETED_MARKER).

mk_config_filter(Path) ->
    PathL = size(Path),
    fun ({metakv, K}) when is_binary(K) ->
            case K of
                <<Path:PathL/binary, _/binary>> ->
                    true;
                _ ->
                    false
            end;
        (_K) ->
            false
    end.

handle_iterate_post(Req, Params) ->
    Path = list_to_binary(proplists:get_value("path", Params)),
    Continuous = erlang:list_to_existing_atom(proplists:get_value("continuous", Params, "false")),
    Filter = mk_config_filter(Path),
    Self = self(),
    HTTPRes = menelaus_util:reply_ok(Req, "application/json; charset=utf-8", chunked),
    ?log_debug("Starting iteration of ~s. Continuous = ~s", [Path, Continuous]),
    case Continuous of
        true ->
            ok = mochiweb_socket:setopts(Req:get(socket), [{active, true}]),
            ns_pubsub:subscribe_link(
              ns_config_events,
              fun ([_|_] = KVs) ->
                      %% we receive kvlist events because they include
                      %% vclocks
                      Self ! {config, KVs};
                  (_) ->
                      ok
              end);
        false ->
            ok
    end,
    KV = ns_config:get_kv_list(),
    [output_kv(HTTPRes, K, V) || {K, V} <- KV,
                                 Filter(K),
                                 ns_config:strip_metadata(V) =/= ?DELETED_MARKER],
    case Continuous of
        true ->
            iterate_loop(HTTPRes, Filter);
        false ->
            HTTPRes:write_chunk("")
    end.

output_kv(HTTPRes, {metakv, K}, V0) ->
    V = ns_config:strip_metadata(V0),
    VC = ns_config:extract_vclock(V0),
    Rev0 = base64:encode(erlang:term_to_binary(VC)),
    {Rev, Value} = case V of
                       ?DELETED_MARKER ->
                           {null, null};
                       _ ->
                           {Rev0, base64:encode(V)}
                   end,
    ?log_debug("Sent ~s rev: ~s", [K, Rev]),
    HTTPRes:write_chunk(ejson:encode({[{rev, Rev},
                                       {path, K},
                                       {value, Value}]})).

iterate_loop(HTTPRes, Filter) ->
    receive
        {config, KVs} ->
            [output_kv(HTTPRes, K, V) || {K, V} <- KVs, Filter(K)],
            iterate_loop(HTTPRes, Filter);
        _ ->
            erlang:exit(normal)
    end.
