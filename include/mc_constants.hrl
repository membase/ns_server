-define(HEADER_LEN, 24).
-define(REQ_MAGIC, 16#80).
-define(RES_MAGIC, 16#81).

% Command codes.
-define(GET,         16#00).
-define(SET,         16#01).
-define(ADD,         16#02).
-define(REPLACE,     16#03).
-define(DELETE,      16#04).
-define(INCREMENT,   16#05).
-define(DECREMENT,   16#06).
-define(QUIT,        16#07).
-define(FLUSH,       16#08).
-define(GETQ,        16#09).
-define(NOOP,        16#0a).
-define(VERSION,     16#0b).
-define(GETK,        16#0c).
-define(GETKQ,       16#0d).
-define(APPEND,      16#0e).
-define(PREPEND,     16#0f).
-define(STAT,        16#10).
-define(SETQ,        16#11).
-define(ADDQ,        16#12).
-define(REPLACEQ,    16#13).
-define(DELETEQ,     16#14).
-define(INCREMENTQ,  16#15).
-define(DECREMENTQ,  16#16).
-define(QUITQ,       16#17).
-define(FLUSHQ,      16#18).
-define(APPENDQ,     16#19).
-define(PREPENDQ,    16#1a).

-define(CMD_SASL_LIST_MECHS, 16#20).
-define(CMD_SASL_AUTH,       16#21).
-define(CMD_SASL_STEP,       16#22).

-define(CMD_CREATE_BUCKET, 16#85).
-define(CMD_DELETE_BUCKET, 16#86).
-define(CMD_LIST_BUCKETS , 16#87).
-define(CMD_EXPAND_BUCKET, 16#88).
-define(CMD_SELECT_BUCKET, 16#89).

-define(CMD_SET_FLUSH_PARAM, 16#82).
-define(CMD_SET_VBUCKET,     16#3d).
-define(CMD_GET_VBUCKET,     16#3e).
-define(CMD_DELETE_VBUCKET,  16#3f).

-define(CMD_DEREGISTER_TAP_CLIENT, 16#9e).

-define(CMD_LAST_CLOSED_CHECKPOINT,  16#97).

-define(RGET,        16#30).
-define(RSET,        16#31).
-define(RSETQ,       16#32).
-define(RAPPEND,     16#33).
-define(RAPPENDQ,    16#34).
-define(RPREPEND,    16#35).
-define(RPREPENDQ,   16#36).
-define(RDELETE,     16#37).
-define(RDELETEQ,    16#38).
-define(RINCR,       16#39).
-define(RINCRQ,      16#3a).
-define(RDECR,       16#3b).
-define(RDECRQ,      16#3c).

-define(TAP_CONNECT,  16#40).
-define(TAP_MUTATION, 16#41).
-define(TAP_DELETE,   16#42).
-define(TAP_FLUSH,    16#43).
-define(TAP_OPAQUE,   16#44).
-define(TAP_VBUCKET,  16#45).

% Response status codes.
-define(SUCCESS,          16#00).
-define(KEY_ENOENT,       16#01).
-define(KEY_EEXISTS,      16#02).
-define(E2BIG,            16#03).
-define(EINVAL,           16#04).
-define(NOT_STORED,       16#05).
-define(DELTA_BADVAL,     16#06).
-define(NOT_MY_VBUCKET,   16#07).
-define(UNKNOWN_COMMAND,  16#81).
-define(ENOMEM,           16#82).
-define(NOT_SUPPORTED,    16#83).
-define(EINTERNAL,        16#84).
-define(EBUSY,            16#85).

% Vbucket States
-define(VB_STATE_ACTIVE, 1).
-define(VB_STATE_REPLICA, 2).
-define(VB_STATE_PENDING, 3).
-define(VB_STATE_DEAD, 4).

% TAP CONNECT flags
-define(BACKFILL,          2#0000001).
-define(DUMP,              2#0000010).
-define(LIST_VBUCKETS,     2#0000100).
-define(TAKEOVER_VBUCKETS, 2#0001000).
-define(SUPPORT_ACK,       2#0010000).
-define(KEYS_ONLY,         2#0100000).
-define(CHECKPOINT,        2#1000000).

-define(TAP_FLAG_ACK,      2#0000001).
-define(TAP_FLAG_NO_VALUE, 2#0000010).

%% EP engine opaque flags
-define(TAP_OPAQUE_ENABLE_AUTO_NACK, 16#00).
-define(TAP_OPAQUE_INITIAL_VBUCKET_STREAM, 16#01).
-define(TAP_OPAQUE_ENABLE_CHECKPOINT_SYNC, 16#02).
-define(TAP_OPAQUE_CLOSE_TAP_STREAM, 16#07).
