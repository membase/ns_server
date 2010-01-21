-type log_classification() :: 'warn' | 'info' | 'crit'.

-record(log_entry, {
          module :: atom(),
          code   :: integer(),
          msg    :: string(),
          args   :: list(),
          cat    :: log_classification(),
          tstamp :: integer()
         }).
