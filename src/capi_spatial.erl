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
%%
-module(capi_spatial).

-include("couch_db.hrl").
-include_lib("couch_index_merger/include/couch_index_merger.hrl").
-include("ns_common.hrl").

-export([handle_spatial_req/3, cleanup_spatial_index_files/1,
         handle_design_info_req/3, spatial_local_info/2,
         handle_compact_req/3, spatial_local_compact/2]).

-define(RETRY_INTERVAL, 5 * 1000).
-define(RETRY_ATTEMPTS, 20).
-define(INFO_TIMEOUT, 60 * 1000).

% The _spatial endpoint is different from others. It has sub-endpoints
% like _spatial/_compact.
% This function splits between a reply to a normal spatial query and
% dispatching of sub-endpoints if the path part after _spatial starts
% with an underscore.
handle_spatial_req(#httpd{
        path_parts=[_, _, _Dname, _, SpatialName|_]}=Req, Db, DDoc) ->
    case SpatialName of
    % the path after _spatial starts with an underscore => dispatch
    <<$_,_/binary>> ->
        dispatch_sub_spatial_req(Req, Db, DDoc);
    _ ->
        handle_spatial(Req, Db, DDoc)
    end.

% the dispatching of endpoints below _spatial needs to be done manually
dispatch_sub_spatial_req(#httpd{
        path_parts=[_, _, _DName, Spatial, SpatialDisp|_]}=Req,
        Db, DDoc) ->
    Conf = couch_config:get("httpd_design_handlers",
        ?b2l(<<Spatial/binary, "/", SpatialDisp/binary>>)),
    Fun = couch_httpd:make_arity_3_fun(Conf),
    Fun(Req, Db, DDoc).


design_doc_spatial(Req, #db{name=BucketName} = Db, DesignName, SpatialName,
                   VBuckets) ->
    DDocId = <<"_design/", DesignName/binary>>,
    Specs = capi_view:build_local_simple_specs(BucketName, DDocId, SpatialName,
                                               VBuckets),
    MergeParams = spatial_merge_params(Req, Db, DDocId, SpatialName, Specs),
    couch_index_merger:query_index(couch_spatial_merger, MergeParams, Req).

design_doc_spatial(Req, Db, DesignName, SpatialName) ->
    DDocId = <<"_design/", DesignName/binary>>,
    design_doc_spatial_loop(Req, Db, DDocId, SpatialName, ?RETRY_ATTEMPTS).

design_doc_spatial_loop(_Req, _Db, _DDocId, _SpatialName, 0) ->
    throw({error, inconsistent_state});
design_doc_spatial_loop(Req, Db, DDocId, SpatialName, Attempt) ->
    MergeParams = spatial_merge_params(Req, Db, DDocId, SpatialName),
    try
        couch_index_merger:query_index(couch_spatial_merger, MergeParams, Req)
    catch
        % Spatial indexes don't supprt set views at the moment, though keeping
        % the code here for future reference doesn't do any harm.
        throw:{error, set_view_outdated} ->
            ?log_debug("Got `set_view_outdated` error. Retrying."),
            timer:sleep(?RETRY_INTERVAL),
            design_doc_spatial_loop(Req, Db, DDocId, SpatialName, Attempt - 1)
    end.

handle_spatial(Req, Db, DDoc) when Db#db.filepath =/= undefined ->
    couch_httpd_spatial:handle_spatial_req(Req, Db, DDoc);

handle_spatial(#httpd{method='GET',
                          path_parts=[_, _, DName, _, SpatialName]}=Req,
                   Db, _DDoc) ->
    do_handle_spatial_req(Req, Db, DName, SpatialName);

handle_spatial(#httpd{method='POST',
                      path_parts=[_, _, DName, _, SpatialName]}=Req, Db, _DDoc) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    do_handle_spatial_req(Req, Db, DName, SpatialName);

handle_spatial(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST,HEAD").

do_handle_spatial_req(Req, #db{name=DbName} = Db, DDocName, SpatialName) ->
    capi_view:when_has_active_vbuckets(
      Req, DbName,
      fun () ->
            case capi_view:run_on_subset(Req, DbName) of
                full_set ->
                    design_doc_spatial(Req, Db, DDocName, SpatialName);
                VBucket ->
                    design_doc_spatial(Req, Db, DDocName, SpatialName, [VBucket])
            end
      end).

spatial_merge_params(Req, #db{name = BucketName} = Db, DDocId, SpatialName) ->
    NodeToVBuckets = vbucket_map_mirror:node_vbuckets_dict(?b2l(BucketName)),
    %% FullSpatialName = case DDocId of
    %% nil ->
    %%     % _all_docs and other special builtin views
    %%     SpatialName;
    %% _ ->
    %%     iolist_to_binary([BucketName, "%2F", "master", $/, DDocId, $/,
    %%         SpatialName])
    %% end,
    DDocName = case DDocId of
                   <<"_design/", Rest/binary>> ->
                       Rest;
                   _ ->
                       DDocId
               end,
    FullSpatialName = iolist_to_binary([BucketName, "%2F", "master", $/,
                                        couch_httpd:quote(DDocName), $/,
                                        couch_httpd:quote(SpatialName)]),
    SpatialSpecs = dict:fold(
                     fun(Node, VBuckets, Acc) when Node =:= node() ->
                             capi_view:build_local_simple_specs(BucketName, DDocId, SpatialName,
                                                                VBuckets) ++ Acc;
                        (Node, VBuckets, Acc) ->
                             [build_remote_specs(
                                Node, BucketName, FullSpatialName, VBuckets) | Acc]
                     end, [], NodeToVBuckets),
    spatial_merge_params(Req, Db, DDocId, SpatialName, SpatialSpecs).

spatial_merge_params(Req, _Db, _DDocId, _SpatialName, SpatialSpecs) ->
    case Req#httpd.method of
        'GET' ->
            Body = [];
        'POST' ->
            {Body} = couch_httpd:json_body_obj(Req)
    end,
    MergeParams0 = #index_merge{indexes = SpatialSpecs},
    % XXX vmx 20110816: couch_httpd_view_merger:apply_http_config/3 should
    %     perhaps be moved into a utils module
    couch_httpd_view_merger:apply_http_config(Req, Body, MergeParams0).

build_remote_specs(Node, BucketName, FullViewName, VBuckets) ->
    MergeURL = capi_utils:capi_url_bin(Node, <<"/_spatial_merge">>,
                                       <<"127.0.0.1">>),
    Props = {[
              {<<"spatial">>,
               {[{capi_view:vbucket_db_name(BucketName, VBId), FullViewName} ||
                    VBId <- VBuckets]}}
             ]},
    #merged_index_spec{url = MergeURL, ejson_spec = Props}.


% Cleans up all unused spatial index files on the local node.
-spec cleanup_spatial_index_files(BucketName::binary()) -> ok.
cleanup_spatial_index_files(BucketName) ->
    FileList = list_index_files(BucketName),
    Sigs = capi_frontend:with_subdb(BucketName, <<"master">>,
                                    fun (RealDb) ->
                                        get_signatures(RealDb)
                                    end),
    delete_unused_files(FileList, Sigs),
    ok.

% Return all file names ending with ".spatial" relative to a certain
% bucket. It returns files of all vbuckets, no matter which type they
% have, i.e. also files from replica vbuckets are returned
-spec list_index_files(BucketName::binary()) -> [file:filename()].
list_index_files(BucketName) ->
    RootDir = couch_config:get("couchdb", "view_index_dir"),
    Wildcard = filename:join([RootDir,
                              "." ++ ?b2l(BucketName),
                              "*_design",
                              "*.spatial"]),
    filelib:wildcard(Wildcard).

% Get the signatures of all Design Documents of a certain database
-spec get_signatures(Db::#db{}) -> [string()].
get_signatures(Db) ->
    {ok, DesignDocs} = couch_db:get_design_docs(Db, no_deletes),
    lists:map(fun couch_spatial_group:get_signature/1, DesignDocs).

% Deletes all files that doesn't match any signature
-spec delete_unused_files(FileList::[string()], Sigs::[string()]) -> ok.
delete_unused_files(FileList, Sigs) ->
    % regex that matches all ddocs
    {ok, Mp} = re:compile("(" ++ string:join(Sigs, "|") ++ ")"),

    % filter out the ones in use
    DeleteFiles = case Sigs of
                      [] ->
                          FileList;
                      _ ->
                          [FilePath || FilePath <- FileList,
                                       re:run(FilePath, Mp,
                                              [{capture, none}]) =:= nomatch]
                  end,
    % delete unused files
    case DeleteFiles of
        [] ->
            ok;
        _ ->
            ?LOG_INFO("(capi_spatial) Deleting unused (old) spatial index files:~n~n~s",
                      [string:join(DeleteFiles, "\n")])
    end,
    RootDir = couch_config:get("couchdb", "view_index_dir"),
    lists:foreach(
      fun(File) -> couch_file:delete(RootDir, File, false) end,
      DeleteFiles).


handle_compact_req(#httpd{method='POST',
        path_parts=[DbName, _ , DName|_]}=Req, Db, _DDoc) ->
    ok = couch_db:check_is_admin(Db),
    couch_httpd:validate_ctype(Req, "application/json"),
    ok = spatial_compact(DbName, DName),
    couch_httpd:send_json(Req, 202, {[{ok, true}]});
handle_compact_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "POST").

-spec spatial_compact(BucketName::binary(), DesignId::binary()) ->
                         ok|no_return().
spatial_compact(BucketName, DesignId) ->
    Nodes = bucket_nodes(BucketName),
    case rpc:multicall(Nodes, capi_spatial, spatial_local_compact,
                       [BucketName, DesignId], ?INFO_TIMEOUT) of
        {_, []} ->
            ok;
        {_, BadNodes} ->
            ?log_error(
               "Failed to get start spatial compaction on some nodes (~p)",
               [BadNodes]),
            throw({502, "no_compaction",
                   "Cannot start compaction on all nodes."})
    end.

% Compact a local spatial index (all vbuckets)
-spec spatial_local_compact(BucketName::binary(), DesignId::binary()) -> ok.
spatial_local_compact(BucketName, DesignId) ->
    VBuckets = get_local_vbuckets(BucketName),
    MasterDbName = <<BucketName/binary, "/master">>,
    lists:foreach(fun(VBucket) ->
        DbName = capi_view:vbucket_db_name(BucketName, VBucket),
        couch_spatial_compactor:start_compact({DbName, MasterDbName}, DesignId)
    end, VBuckets),
    ok.


handle_design_info_req(#httpd{method='GET', path_parts=
                                  [_, _, DesignName, _, _]}=Req,
                       #db{name=BucketName}, _DDoc) ->
    DesignId = <<"_design/", DesignName/binary>>,
    Infos = spatial_info(BucketName, DesignId),
    couch_httpd:send_json(Req, 200, {[{name, DesignName},
                                      {spatial_index, {Infos}}
                                     ]});

handle_design_info_req(Req, _Db, _DDoc) ->
    couch_httpd:send_method_not_allowed(Req, "GET").

% Get the spatial info from all nodes and merge it
-spec spatial_info(BucketName::binary(), DesignId::binary()) ->
                      [{atom(), any()}]|no_return().
spatial_info(BucketName, DesignId) ->
    Nodes = bucket_nodes(BucketName),
    case rpc:multicall(Nodes, capi_spatial, spatial_local_info,
                       [BucketName, DesignId], ?INFO_TIMEOUT) of
        {Infos, []} ->
            merge_infos(Infos);
        {_, BadNodes} ->
            ?log_error("Failed to get spatial _info from some nodes (~p)",
                       [BadNodes]),
            throw({502, "no_info", "Cannot get spatial _info from all nodes."})
    end.

% Get the info of a local spatial index (all vbuckets)
-spec spatial_local_info(BucketName::binary(), DesignId::binary()) ->
                            [{atom(), any()}].
spatial_local_info(BucketName, DesignId) ->
    MasterDbName = <<BucketName/binary, "/master">>,
    VBuckets = get_local_vbuckets(BucketName),
    Infos = lists:map(
              fun(VBucket) ->
                  DbName = capi_view:vbucket_db_name(BucketName, VBucket),
                  {ok, GroupInfoList} = couch_spatial:get_group_info(
                                          {DbName, MasterDbName},
                                          DesignId),
                  GroupInfoList
              end, VBuckets),
    merge_infos(Infos).

% Returns the *active* vBuckets of the current node, not the replicas
-spec get_local_vbuckets(BucketName::binary()) -> [integer()].
get_local_vbuckets(BucketName) ->
    Me = node(),
    {ok, BucketConfig} = ns_bucket:get_bucket(?b2l(BucketName)),
    VBucketMap = couch_util:get_value(map, BucketConfig, []),
    {_, VBuckets} = lists:foldl(
                      fun(Nodes, {Index, LocalVBuckets}) ->
                          % Only return active vBuckets
                          case hd(Nodes) =:= Me of
                              true ->
                                  {Index + 1, [Index|LocalVBuckets]};
                              false ->
                                  {Index + 1, LocalVBuckets}
                          end
                      end,
                      {0, []}, VBucketMap),
    VBuckets.

% Merge the information from all vBuckets
-spec merge_infos(Infos::[[{atom(), any()}]]) -> [{atom(), any()}].
merge_infos([I|Infos]) ->
    lists:foldl(
      fun(Info, Acc) ->
          [{signature, proplists:get_value(signature, Info)},
           {language, proplists:get_value(language, Info)},
           {disk_size, proplists:get_value(disk_size, Acc) +
                proplists:get_value(disk_size, Info)},
           {updater_running, property_true(updater_running, Acc, Info)},
           {compact_running, property_true(compact_running, Acc, Info)},
           {waiting_commit, property_true(waiting_commit, Acc, Info)},
           {waiting_clients, proplists:get_value(waiting_clients, Acc) +
                proplists:get_value(waiting_clients, Info)},
           {update_seq, merge_number_list(
                          proplists:get_value(update_seq, Acc),
                          proplists:get_value(update_seq, Info))},
           {purge_seq, merge_number_list(
                         proplists:get_value(purge_seq, Acc),
                         proplists:get_value(purge_seq, Info))}]
      end, I, Infos).

% Returns true if one of the given property of the proplists is true
-spec property_true(Prop::atom(), A::[{atom(), boolean()}],
                    B::[{atom(), boolean()}]) ->
                       boolean().
property_true(Prop, A, B) ->
    proplists:get_value(Prop, A) or proplists:get_value(Prop, B).

% Merges a number/list of numbers with a number/list of numbers into a new list
-spec merge_number_list(A::number()|list(), B::number()|list()) -> [number()].
merge_number_list(A, B) when is_number(A) and is_number(B) ->
    [A, B];
merge_number_list(A, B) when is_number(A) and is_list(B) ->
    [A|B];
merge_number_list(A, B) when is_list(A) and is_number(B) ->
    A ++ [B];
merge_number_list(A, B) when is_list(A) and is_list(B) ->
    A ++ B.

bucket_nodes(BucketName) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(?b2l(BucketName)),
    ns_bucket:bucket_nodes(BucketConfig).
