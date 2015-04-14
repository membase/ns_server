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
        "recursive_delete" ->
            handle_recursive_delete_post(Req, Params);
        "iterate" ->
            handle_iterate_post(Req, Params)
    end.

handle_get_post(Req, Params) ->
    Path = list_to_binary(proplists:get_value("path", Params)),
    case metakv:get(Path) of
        false ->
            menelaus_util:reply_json(Req, {[]});
        {value, Val0} ->
            Val = base64:encode(Val0),
            menelaus_util:reply_json(Req, {[{value, Val}]});
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

handle_mutate(Req, Params, Value) ->
    Start = os:timestamp(),
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
    case metakv:mutate(Path, Value, Rev) of
        ok ->
            ElapsedTime = timer:now_diff(os:timestamp(), Start) div 1000,
            %% TODO: Do not display sensitive values.
            ?log_debug("Updated ~p to hold ~p~n. Elapsed time:~p ms.~n",
                       [Path, Value, ElapsedTime]),
            menelaus_util:reply(Req, 200);
        Error ->
            %% TODO: Discuss with Aliaksey.
            %% Error will be one of: flush_failed, retry_needed,
            %% {abort, mismatch}. Earlier we returned 409 error
            %% only for {abort, mismatch}.
            %% OK to return 409 for flush_failed and retry_needed
            %% as well?
            ?log_debug("Failed to update ~p with error ~p.~n",
                       [Path, Error]),
            menelaus_util:reply(Req, 409)
    end.

handle_set_post(Req, Params) ->
    Value = list_to_binary(proplists:get_value("value", Params)),
    handle_mutate(Req, Params, Value).

handle_delete_post(Req, Params) ->
    handle_mutate(Req, Params, ?DELETED_MARKER).

handle_recursive_delete_post(Req, Params) ->
    ?log_debug("handle_recursive_delete_post: ~p ~n", [Params]),
    Path = list_to_binary(proplists:get_value("path", Params)),
    case metakv:delete_matching(Path) of
        ok ->
            ?log_debug("Recursively deleted children of ~p~n", [Path]),
            menelaus_util:reply(Req, 200);
        Error ->
            ?log_debug("Recursive deletion failed for ~p with error ~p.~n",
                       [Path, Error]),
            menelaus_util:reply(Req, 409)
    end.

handle_iterate_post(Req, Params) ->
    Path = list_to_binary(proplists:get_value("path", Params)),
    Continuous = erlang:list_to_existing_atom(proplists:get_value("continuous", Params, "false")),
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
    KV = metakv:iterate_matching(Path),
    lists:foreach(
      fun({K, V}) ->
              output_kv(HTTPRes, K, V)
      end,
      KV),
    case Continuous of
        true ->
            iterate_loop(HTTPRes, Path);
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
                                       {value, Value}]}));

%% Keys (e.g. XDCR ckpt) stored in simple-store do not have metakv tag
%% and revisions.
output_kv(HTTPRes, K, V) ->
    ?log_debug("Sent ~s", [K]),
    HTTPRes:write_chunk(ejson:encode({[{rev, null},
                                       {path, K},
                                       {value, base64:encode(V)}]})).
iterate_loop(HTTPRes, Path) ->
    receive
        {config, KVs} ->
            KV = metakv:iterate_matching(Path, KVs),
            lists:foreach(
              fun({K, V}) ->
                      output_kv(HTTPRes, K, V)
              end,
              KV),
            iterate_loop(HTTPRes, Path);
        _ ->
            erlang:exit(normal)
    end.

