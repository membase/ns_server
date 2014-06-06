-record(remote_node, {host :: string(),
                      port :: integer(),
                      memcached_port :: integer(),
                      ssl_proxy_port :: pos_integer() | undefined | needed_but_unknown,
                      https_port :: pos_integer() | undefined | needed_but_unknown,
                      https_capi_port :: pos_integer() | undefined | needed_but_unknown
                     }).

-record(remote_cluster, {uuid :: binary(),
                         nodes :: [#remote_node{}],
                         cert :: binary() | undefined
                        }).

-type remote_bucket_node() :: {Host :: binary(), MCDPort :: integer()}.

-record(remote_bucket, {name :: binary(),
                        uuid :: binary(),
                        password :: binary(),
                        cluster_uuid :: binary(),
                        cluster_cert :: binary() | undefined,
                        server_list_nodes :: [#remote_node{}],
                        bucket_caps :: [binary()],
                        raw_vbucket_map :: dict(),
                        capi_vbucket_map :: dict(),
                        cluster_version :: {integer(), integer()}}).
