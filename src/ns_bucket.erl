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
%%
-module(ns_bucket).

-include("ns_common.hrl").

%% API
-export([config/1,
         ensure_bucket/2,
         get_bucket/1,
         get_buckets/0,
         ram_quota/1,
         hdd_quota/1,
         num_replicas/1,
         bucket_type/1,
         auth_type/1,
         sasl_password/1,
         moxi_port/1,
         get_bucket_names/0,
         json_map/2,
         set_bucket_config/2,
         is_valid_bucket_name/1,
         create_bucket/3,
         update_bucket_props/2,
         update_bucket_props/3,
         delete_bucket/1,
         set_map/2,
         set_servers/2]).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
config(Bucket) ->
    {ok, CurrentConfig} = get_bucket(Bucket),
    NumReplicas = proplists:get_value(num_replicas, CurrentConfig),
    NumVBuckets = proplists:get_value(num_vbuckets, CurrentConfig),
    Map = case proplists:get_value(map, CurrentConfig) of
              undefined -> lists:duplicate(NumVBuckets, lists:duplicate(NumReplicas+1, undefined));
              M -> M
          end,
    Servers = proplists:get_value(servers, CurrentConfig),
    {NumReplicas, NumVBuckets, Map, Servers}.


%% @doc Make sure the given bucket exists. Returns a list of nodes it
%% wasn't able to check.
ensure_bucket(Bucket, Nodes) ->
    {Replies, BadNodes} = ns_memcached:stats_multi(Nodes, Bucket),
    {MissingNodes, BadReplyNodes} =
        lists:foldl(fun ({_, {ok, _}}, Acc) ->
                            Acc;
                        ({Node, {memcached_error, mc_status_key_enoent, _}},
                         {M, B}) ->
                            {[Node|M], B};
                        ({Node, Error}, {M, B}) ->
                            ?log_warning("Bad reply from ~p checking bucket "
                                         "~p:~n~p", [Node, Bucket, Error]),
                            {M, [Node|B]}
                    end, {[], []}, Replies),
    lists:foreach(
      fun (Node) ->
              ConfigString = config_string(Node, Bucket),
              ?log_info("Creating bucket ~p on node ~p with config '~s'.",
                        [Bucket, Node, ConfigString]),
              ns_memcached:create_bucket(Node, Bucket, ConfigString)
      end, MissingNodes),
    BadNodes ++ BadReplyNodes.


get_bucket(Bucket) ->
    BucketConfigs = get_buckets(),
    case lists:keysearch(Bucket, 1, BucketConfigs) of
        {value, {_, Config}} ->
            {ok, Config};
        false -> not_present
    end.

get_bucket_names() ->
    % The config just has the list of bucket names right now.
    BucketConfigs = get_buckets(),
    proplists:get_keys(BucketConfigs).

get_buckets() ->
    Config = ns_config:get(),
    ns_config:search_prop(Config, buckets, configs, []).

ram_quota(Bucket) ->
    case proplists:get_value(ram_quota, Bucket) of
        X when is_integer(X) ->
            X
    end.

hdd_quota(Bucket) ->
    case proplists:get_value(hdd_quota, Bucket, 0) of
        X when is_integer(X) ->
            X
    end.

num_replicas(Bucket) ->
    case proplists:get_value(num_replicas, Bucket) of
        X when is_integer(X) ->
            X
    end.

bucket_type(_Bucket) ->
    membase.

auth_type(Bucket) ->
    proplists:get_value(auth_type, Bucket).

sasl_password(Bucket) ->
    proplists:get_value(sasl_password, Bucket).

moxi_port(Bucket) ->
    proplists:get_value(moxi_port, Bucket).

json_map(BucketId, LocalAddr) ->
    Config = ns_config:get(),
    {NumReplicas, _, EMap, BucketNodes} = config(BucketId),
    ENodes = lists:delete(undefined, lists:usort(lists:append([BucketNodes |
                                                               EMap]))),
    Servers = lists:map(
                fun (ENode) ->
                        Port = ns_config:search_node_prop(ENode, Config,
                                                          memcached, port),
                        Host = case misc:node_name_host(ENode) of
                                   {_Name, "127.0.0.1"} -> LocalAddr;
                                   {_Name, H} -> H
                               end,
                        list_to_binary(Host ++ ":" ++ integer_to_list(Port))
                end, ENodes),
    Map = lists:map(fun (Chain) ->
                            lists:map(fun (undefined) -> -1;
                                          (N) -> misc:position(N, ENodes) - 1
                                      end, Chain)
                    end, EMap),
    {struct, [{hashAlgorithm, <<"CRC">>},
              {numReplicas, NumReplicas},
              {serverList, Servers},
              {vBucketMap, Map}]}.

set_bucket_config(Bucket, NewConfig) ->
    update_bucket_config(Bucket, fun (_) -> NewConfig end).

%% Here's code snippet from bucket-engine.  We also disallow '.' &&
%% '..' which cause problems with browsers even when properly
%% escaped. See bug 953
%%
%% static bool has_valid_bucket_name(const char *n) {
%%     bool rv = strlen(n) > 0;
%%     for (; *n; n++) {
%%         rv &= isalpha(*n) || isdigit(*n) || *n == '.' || *n == '%' || *n == '_' || *n == '-';
%%     }
%%     return rv;
%% }
is_valid_bucket_name([]) -> false;
is_valid_bucket_name(".") -> false;
is_valid_bucket_name("..") -> false;
is_valid_bucket_name([Char | Rest]) ->
    case ($A =< Char andalso Char =< $Z)
        orelse ($a =< Char andalso Char =< $z)
        orelse ($0 =< Char andalso Char =< $9)
        orelse Char =:= $. orelse Char =:= $%
        orelse Char =:= $_ orelse Char =:= $- of
        true ->
            case Rest of
                [] -> true;
                _ -> is_valid_bucket_name(Rest)
            end;
        _ -> false
    end.

create_bucket(membase, BucketName, NewConfig) ->
    case is_valid_bucket_name(BucketName) of
        false ->
            {error, {invalid_name, BucketName}};
        _ ->
            %% TODO: handle bucketType of memcache || membase
            MergedConfig =
                misc:update_proplist(
                  [{num_vbuckets,
                    case (catch list_to_integer(os:getenv("VBUCKETS_NUM"))) of
                        EnvBuckets when is_integer(EnvBuckets) -> EnvBuckets;
                        _ -> 1024
                    end},
                   {num_replicas, 1},
                   {ram_quota, 0},
                   {hdd_quota, 0},
                   {ht_size, 3079},
                   {ht_locks, 5},
                   {servers, []},
                   {map, undefined}],
                  NewConfig),
            ns_config:update_sub_key(
              buckets, configs,
              fun (List) ->
                      case lists:keyfind(BucketName, 1, List) of
                          false -> ok;
                          Tuple ->
                              exit({already_exists, Tuple})
                      end,
                      [{BucketName, MergedConfig} | List]
              end)
            %% The janitor will handle creating the map.
    end;
create_bucket(memcache, _BucketName, _NewConfig) ->
    error.

delete_bucket(BucketName) ->
    ns_config:update_sub_key(buckets, configs,
                             fun (List) ->
                                     case lists:keyfind(BucketName, 1, List) of
                                         false -> exit({not_found, BucketName});
                                         Tuple ->
                                             lists:delete(Tuple, List)
                                     end
                             end).

%% Updates properties of bucket of given name and type.  Check of type
%% protects us from type change races in certain cases.
%%
%% If bucket with given name exists, but with different type, we
%% should return {exit, {not_found, _}, _}
update_bucket_props(membase, BucketName, Props) ->
    update_bucket_props(BucketName, Props).

update_bucket_props(BucketName, Props) ->
    ns_config:update_sub_key(buckets, configs,
                             fun (List) ->
                                     RV = misc:key_update(BucketName, List,
                                                          fun (OldProps) ->
                                                                  lists:foldl(fun ({K, _V} = Tuple, Acc) ->
                                                                                      [Tuple | lists:keydelete(K, 1, Acc)]
                                                                              end, OldProps, Props)
                                                          end),
                                     case RV of
                                         false -> exit({not_found, BucketName});
                                         _ -> ok
                                     end,
                                     RV
                             end).

set_map(Bucket, Map) ->
    ChainLengths = [length(Chain) || Chain <- Map],
    true = lists:max(ChainLengths) == lists:min(ChainLengths),
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(map, 1, OldConfig, {map, Map})
      end).

set_servers(Bucket, Servers) ->
    update_bucket_config(
      Bucket,
      fun (OldConfig) ->
              lists:keyreplace(servers, 1, OldConfig, {servers, Servers})
      end).

% Update the bucket config atomically.
update_bucket_config(Bucket, Fun) ->
    ok = ns_config:update_key(
           buckets,
           fun (List) ->
                   Buckets = proplists:get_value(configs, List, []),
                   OldConfig = proplists:get_value(Bucket, Buckets),
                   NewConfig = Fun(OldConfig),
                   NewBuckets = lists:keyreplace(Bucket, 1, Buckets, {Bucket, NewConfig}),
                   lists:keyreplace(configs, 1, List, {configs, NewBuckets})
           end).


%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Check the current config against the list of buckets on this server.
config_string(Node, BucketName) ->
    Config = ns_config:get(),
    DBDir = ns_config:search_node_prop(Node, Config, memcached, dbdir),
    DBName = filename:join(DBDir, BucketName),
    BucketConfigs = ns_config:search_prop(Config, buckets, configs),
    BucketConfig = proplists:get_value(BucketName, BucketConfigs),
    MemQuota = proplists:get_value(ram_quota, BucketConfig),
    Engine = ns_config:search_node_prop(ns_config:get(), memcached, engine),
    ok = filelib:ensure_dir(DBName),
    lists:flatten(
      io_lib:format(
        "~s" ++ [0] ++ "vb0=false;ht_size=~p;ht_locks=~p;max_size=~p;dbname=~s",
        [Engine,
         proplists:get_value(ht_size, BucketConfig),
         proplists:get_value(ht_locks, BucketConfig),
         MemQuota, DBName])).
