-type log_classification() :: 'warn' | 'info' | 'crit'.

-record(log_entry, {
          tstamp      :: erlang:timestamp(),
          node        :: atom(),
          module      :: atom(),
          code        :: integer(),
          msg         :: string(),
          args        :: list(),
          cat         :: log_classification(),
          server_time :: calendar:datetime1970()
         }).
