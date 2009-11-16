-record(mc_msg, {cmd = "",
                 key = "",
                 keys = [],
                 flag = 0,
                 expire = 0,
                 cas = 0,
                 data = <<>>,
                 datatype = 0}).

-record(mc_header, {status = 0,
                    opaque = 0,
                    keylen = 0,
                    extlen = 0,
                    bodylen = 0}).

