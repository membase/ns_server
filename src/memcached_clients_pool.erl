-module(memcached_clients_pool).

-include("ns_common.hrl").
-include("remote_clusters_info.hrl").

-export([start_link/0,
         make_loc_by_remote_cluster_info_ref/3,
         make_loc/4]).

-export([take_socket/1, put_socket/2]).

start_link() ->
    Options = [{name, memcached_clients_pool},
               {connection_timeout, 30000},
               {pool_size, 200}],
    ns_connection_pool:start_link(Options).

take_socket({?MODULE, {Host, Port, Bucket, Auth}}) ->
    case ns_connection_pool:maybe_take_socket(memcached_clients_pool, {Host, Port, Bucket}) of
        {ok, _S} = Ok ->
            Ok;
        no_socket ->
            establish_connection(Host, Port, Bucket, Auth)
    end.

establish_connection(Host, Port, Bucket, Password) ->
    case gen_tcp:connect(Host, Port, [binary, {packet, 0}, {keepalive, true}, {nodelay, true}, {active, false}]) of
        {ok, S} ->
            case mc_client_binary:auth(S, {<<"PLAIN">>,
                                           {list_to_binary(Bucket),
                                            list_to_binary(Password)}}) of
                ok ->
                    {ok, S};
                {memcached_error, _, _} = McdError ->
                    {error, {auth_failed, McdError}}
            end;
        {error, _ } = Error ->
            Error
    end.

put_socket(Socket, {?MODULE, {Host, Port, Bucket, _Auth}}) ->
    ns_connection_pool:put_socket(memcached_clients_pool, {Host, Port, Bucket}, Socket).

make_loc_by_remote_cluster_info_ref(TargetRef, Through, VBucket) ->
    case remote_clusters_info:get_memcached_vbucket_info_by_ref(TargetRef, Through, VBucket) of
        {ok, #remote_node{host = HostString, memcached_port = Port}, BucketInfo} ->
            {ok, {_ClusterUUID, BucketName}} = remote_clusters_info:parse_remote_bucket_reference(TargetRef),
            Password = binary_to_list(BucketInfo#remote_bucket.password),
            {ok, {?MODULE, {list_to_binary(HostString), Port, BucketName, Password}}};
        Error ->
            Error
    end.

make_loc(Host, Port, Bucket, Password) ->
    {?MODULE, {Host, Port, Bucket, Password}}.
