-record(remote_node, {host :: string(),
                      port :: integer()}).

-record(remote_cluster, {uuid :: binary(),
                         nodes :: [#remote_node{}]}).

-record(remote_bucket, {uuid :: binary(),
                        cluster_uuid :: binary(),
                        vbucket_map :: dict()}).
