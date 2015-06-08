-record(config, {init,         % Initialization parameters.
                 static = [],  % List of TupleList's; TupleList is {K, V}.
                 dynamic = [], % List of TupleList's; TupleList is {K, V}.
                 policy_mod,
                 saver_mfa,
                 saver_pid,
                 pending_more_save = false,
                 uuid,
                 upgrade_config_fun
                }).
-define(METADATA_VCLOCK, '_vclock').
-define(DELETED_MARKER, '_deleted').
