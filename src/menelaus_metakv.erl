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
    Sensitive = proplists:get_value("sensitive", Params) =:= "true",
    case metakv:mutate(Path, Value,
                        [{rev, Rev}, {?METAKV_SENSITIVE, Sensitive}]) of
        ok ->
            ElapsedTime = timer:now_diff(os:timestamp(), Start) div 1000,
            %% Values are already displayed by ns_config_log and simple_store.
            %% ns_config_log is smart enough to not log sensitive values
            %% and simple_store does not store senstive values.
            ?log_debug("Updated ~p. Elapsed time:~p ms.", [Path, ElapsedTime]),
            menelaus_util:reply(Req, 200);
        Error ->
            ?log_debug("Failed to update ~p with error ~p.", [Path, Error]),
            menelaus_util:reply(Req, 409)
    end.

handle_set_post(Req, Params) ->
    Value = list_to_binary(proplists:get_value("value", Params)),
    handle_mutate(Req, Params, Value).

handle_delete_post(Req, Params) ->
    handle_mutate(Req, Params, ?DELETED_MARKER).

handle_recursive_delete_post(Req, Params) ->
    ?log_debug("handle_recursive_delete_post: ~p", [Params]),
    Path = list_to_binary(proplists:get_value("path", Params)),
    case metakv:delete_matching(Path) of
        ok ->
            ?log_debug("Recursively deleted children of ~p", [Path]),
            menelaus_util:reply(Req, 200);
        Error ->
            ?log_debug("Recursive deletion failed for ~p with error ~p.",
                       [Path, Error]),
            menelaus_util:reply(Req, 409)
    end.

handle_iterate_post(Req, Params) ->
    Path = list_to_binary(proplists:get_value("path", Params)),
    Continuous = proplists:get_value("continuous", Params, "false") =:= "true",
    case Continuous =/= true orelse metakv:check_continuous_allowed(Path) of
        true ->
            handle_iterate(Req, Path, Continuous);
        false ->
            %% Return http error - 405: Method Not Allowed
            menelaus_util:reply(Req, 405)
    end.

handle_iterate(Req, Path, Continuous) ->
    HTTPRes = menelaus_util:reply_ok(Req, "application/json; charset=utf-8", chunked),
    ?log_debug("Starting iteration of ~s. Continuous = ~s", [Path, Continuous]),
    case Continuous of
        true ->
            ok = mochiweb_socket:setopts(Req:get(socket), [{active, true}]);
        false ->
            ok
    end,
    RV = metakv:iterate_matching(Path, Continuous,
                                 fun({K, V, VC}) ->
                                         output_kv(HTTPRes, K, V, VC);
                                    ({K, V}) ->
                                         output_kv(HTTPRes, K, V, undefined)
                                 end),
    case Continuous of
        true ->
            RV;
        false ->
            HTTPRes:write_chunk("")
    end.

output_kv(HTTPRes, K, V, undefined) ->
    ?log_debug("Sent ~s", [K]),
    HTTPRes:write_chunk(ejson:encode({[{rev, null},
                                       {path, K},
                                       {value, base64:encode(V)}]}));
output_kv(HTTPRes, K, V, VC) ->
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

