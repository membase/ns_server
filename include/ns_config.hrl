-record(config, {init,         % Initialization parameters.
                 static = [],  % List of TupleList's; TupleList is {K, V}.
                 dynamic = [], % List of TupleList's; TupleList is {K, V}.
                 policy_mod
                }).
-define(METADATA_VER, '_ver').

