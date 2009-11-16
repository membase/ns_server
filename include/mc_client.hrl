-record(mc_msg, {cmd = undefined,
                 key = undefined,
                 keys = [],
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

