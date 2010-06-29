-type log_classification() :: 'warn' | 'info' | 'crit'.

-record(log_entry, {
          tstamp :: {integer(), integer(), integer()},
          node   :: atom(),
          module :: atom(),
          code   :: integer(),
          msg    :: string(),
          args   :: list(),
          cat    :: log_classification()
         }).
