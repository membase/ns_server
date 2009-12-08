-record(mc_entry, {key = undefined,
                   ext = undefined,
                   flag = 0,
                   expire = 0,
                   cas = 0,
                   data = undefined,
                   datatype = 0}).

-record(mc_header, {opcode = 0,
                    status = 0, % Used for both status & reserved field.
                    keylen = undefined,
                    extlen = undefined,
                    bodylen = undefined,
                    opaque = 0}).

-record(mc_config, {version = 1,   % config file version
                    directory,
                    replica_n = 1,
                    replica_w = 1,
                    replica_r = 1}).

-record(mc_pool, {id,     % Pool id.
                  addrs,  % [OpaqueAddr], not necessarily [mc_addr].
                  config, % [{key, value}].
                  buckets % [OpaqueBucket], not necessarily [mc_bucket].
                  }).

-record(mc_bucket, {id,    % Bucket id.
                    addrs, % [OpaqueAddr], not necessarily [mc_addr].
                    config % [{key, value}].
                    }).

% Note: we may use mc_addr as keys in dict/ets tables,
%       so they need to be scalar-ish or matchable.

-record(mc_addr, {location, % eg, "localhost:11211"
                  kind      % eg, binary or ascii
                  % TODO: bucket name? pool name? auth creds?
                  }).

-record(config, {n=3, r=1, w=1, q=6, directory, web_port, text_port=11222,
                 storage_mod=storage_dets, blocksize=4096,
                 thrift_port=9200, pb_port=undefined,
                 buffered_writes=undefined,
                 cache=undefined, cache_size=1048576}).

-define(CHUNK_SIZE, 5120).

