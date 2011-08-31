-include("ns_common.hrl").

%% The range used within this file is arbitrary and undefined, so I'm
%% defining an arbitrary value here just to be rebellious.
-define(BUCKET_DELETED, 11).
-define(BUCKET_CREATED, 12).
-define(START_FAIL, 100).
-define(NODE_EJECTED, 101).
-define(UI_SIDE_ERROR_REPORT, 102).

-define(MENELAUS_WEB_LOG(Code, Msg, Args),
        ?user_log_mod(menelaus_web, Code, Msg, Args)).
