-record(upr_packet, {
          opcode :: non_neg_integer(),
          datatype = 0 :: non_neg_integer(),
          vbucket = 0 :: non_neg_integer(),
          status = 0 :: non_neg_integer(),
          opaque = 0 :: non_neg_integer(),
          cas = 0:: non_neg_integer(),
          ext = <<>> :: binary(),
          key = <<>> :: binary(),
          body = <<>> :: binary()
}).

-record(upr_mutation, {id,
                       local_seq,
                       rev,
                       body,
                       deleted,
                       snapshot_start_seq,
                       snapshot_end_seq
}).

-type callback_arg() :: #upr_mutation{} | {failover_id, term()} | stream_end.
-type callback_fun() :: fun((callback_arg(), any()) -> {ok, any()} | {stop, any()}).
