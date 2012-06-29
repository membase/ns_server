-define(VERSION_200, '2.0.0').

-define(COMPATIBILITY_LIST, [?VERSION_200]).

-record(version_info,
        {version :: atom(),
         raw_version :: string(),
         compatible_versions :: [atom()]}).
