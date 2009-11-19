-record(mc_entry, {key = undefined,
                   keys = [], % TODO: Move this somewhere else.
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

-record(mc_bucket, {pool, addrs, key}).

