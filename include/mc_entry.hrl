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

-record(mc_pool, {addrs,  % [OpaqueAddr], not necessarily [mc_addr].
                  buckets % [OpaqueBucket], not necessarily [mc_bucket].
                  }).

-record(mc_bucket, {id,   % Bucket id.
                    addrs % [OpaqueAddr], not necessarily [mc_addr].
                    }).

% Note: we may use mc_addr as keys in dict/ets tables,
%       so they need to be scalar-ish or matchable.

-record(mc_addr, {location, % eg, "localhost:11211"
                  kind      % eg, binary or ascii
                  % TODO: bucket name? pool name? auth creds?
                  }).
