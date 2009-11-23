-record(mc_entry, {key = undefined,
                   ext = undefined,
                   flag = 0,
                   expire = 0,
                   cas = 0,
                   data = undefined,
                   datatype = 0}).

-record(mc_header, {opcode = 0,
                    statusOrReserved = 0,
                    keylen = undefined,
                    extlen = undefined,
                    bodylen = undefined,
                    opaque = 0}).

-record(mc_pool, {addrs = [], buckets = []}).

-record(mc_bucket, {id,   % Bucket id.
                    pool, % An opaque Pool, not necessarily an mc_pool.
                    addrs % [Addr], not ncessary [mc_addr].
                    }).

-record(mc_addr, {location, % eg, "localhost:11211"
                  kind      % eg, binary or ascii
                  % TODO: bucket name? pool name? auth creds?
                  }).
