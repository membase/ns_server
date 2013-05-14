%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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

-module(menelaus_web_recovery).

-import(menelaus_util,
        [reply_json/2,
         reply_json/3]).

-export([handle_start_recovery/3,
         handle_recovery_status/3,
         handle_stop_recovery/3,
         handle_commit_vbucket/3]).

handle_start_recovery(_PooldId, Bucket, Req) ->
    case ns_orchestrator:start_recovery(Bucket) of
        {ok, UUID, RecoveryMap} ->
            reply_json(Req, build_start_recovery_reply(UUID, RecoveryMap));
        Error ->
            reply_common(Req, Error)
    end.

handle_recovery_status(_PoolId, Bucket, Req) ->
    UUID = proplists:get_value("recovery_uuid", Req:parse_qs()),

    case UUID of
        undefined ->
            reply_common(Req, uuid_missing);
        _ ->
            UUIDBinary = list_to_binary(UUID),
            case ns_orchestrator:recovery_map(Bucket, UUIDBinary) of
                {ok, Map} ->
                    reply_json(Req, build_start_recovery_reply(UUIDBinary, Map));
                Error ->
                    reply_common(Req, Error)
            end
    end.

handle_stop_recovery(_PoolId, Bucket, Req) ->
    UUID = proplists:get_value("recovery_uuid", Req:parse_qs()),

    Reply =
        case UUID of
            undefined ->
                uuid_missing;
            _ ->
                UUIDBinary = list_to_binary(UUID),
                ns_orchestrator:stop_recovery(Bucket, UUIDBinary)
        end,

    reply_common(Req, Reply).

handle_commit_vbucket(_PoolId, Bucket, Req) ->
    UUID = proplists:get_value("recovery_uuid", Req:parse_qs()),
    VBucket = proplists:get_value("vbucket", Req:parse_post()),

    Reply =
        case UUID of
            undefined ->
                uuid_missing;
            _ ->
                UUIDBinary = list_to_binary(UUID),
                try list_to_integer(VBucket) of
                    V when is_integer(V) ->
                        ns_orchestrator:commit_vbucket(Bucket, UUIDBinary, V)
                catch
                    error:badarg ->
                        bad_or_missing_vbucket
                end
        end,

    reply_common(Req, Reply).

%% internal
build_start_recovery_reply(UUID, RecoveryMap) ->
    {struct, [{uuid, UUID},
              {code, ok},
              {recoveryMap, build_recovery_map_json(RecoveryMap)}]}.

build_recovery_map_json(RecoveryMap) ->
    dict:fold(
      fun (Node, VBuckets, Acc) ->
              JSON = {struct, [{node, Node},
                               {vbuckets, VBuckets}]},
              [JSON | Acc]
      end, [], RecoveryMap).

reply_common(Req, Reply0) ->
    Reply = extract_reply(Reply0),
    Status = reply_status_code(Reply),
    Code = reply_code(Reply),
    Extra = build_common_reply_extra(Reply),

    JSON = {struct, [{code, Code} | Extra]},
    reply_json(Req, JSON, Status).

build_common_reply_extra({failed_nodes, Nodes}) ->
    [{failedNodes, Nodes}];
build_common_reply_extra(Reply) when is_atom(Reply) ->
    [].

extract_reply({error, Error}) ->
    Error;
extract_reply(Reply) ->
    Reply.

reply_code({failed_nodes, _}) ->
    failed_nodes;
reply_code(Reply) when is_atom(Reply) ->
    Reply.

reply_status_code(ok) ->
    200;
reply_status_code(recovery_completed) ->
    200;
reply_status_code(not_present) ->
    404;
reply_status_code(bad_recovery) ->
    404;
reply_status_code(vbucket_not_found) ->
    404;
reply_status_code({failed_nodes, _}) ->
    500;
reply_status_code(rebalance_running) ->
    503;
reply_status_code(Error) when is_atom(Error) ->
    400.
