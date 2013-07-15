-record(remote_node, {host :: string(),
                      port :: integer()}).

-record(remote_cluster, {uuid :: binary(),
                         nodes :: [#remote_node{}]}).

-type remote_bucket_node() :: {Host :: binary(), MCDPort :: integer()}.

-record(remote_bucket, {uuid :: binary(),
                        password :: binary(),
                        cluster_uuid :: binary(),
                        server_list :: [remote_bucket_node()],
                        raw_vbucket_map :: dict(),
                        capi_vbucket_map :: dict()}).
