-ifdef(LOG_DEBUG).
-undef(LOG_DEBUG).
-endif.

-ifdef(LOG_INFO).
-undef(LOG_INFO).
-endif.

-ifdef(LOG_ERROR).
-undef(LOG_ERROR).
-endif.

-define(LOG_DEBUG(Format, Args), couch_log:debug(Format, Args)).
-define(LOG_INFO(Format, Args), couch_log:info(Format, Args)).
-define(LOG_ERROR(Format, Args), couch_log:error(Format, Args)).
