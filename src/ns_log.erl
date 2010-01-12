% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_log).

-export([log/3, log/4, recent/0]).

-include_lib("eunit/include/eunit.hrl").

%% API

% A Code is an number which is module-specific.
%
-spec log(atom(), integer(), string()) -> ok.
log(Module, Code, Msg) ->
    error_logger:info_msg("~p-~p: ~p", [Module, Code, Msg]),
    ok.

-spec log(atom(), integer(), string(), list()) -> ok.
log(Module, Code, Fmt, Args) ->
    error_logger:info_msg("~p-~p: " ++ Fmt, [Module, Code | Args]),
    ok.

-spec recent() -> list({atom(), integer(), string(), list()}).
recent() ->
    [].

% TODO: Implement this placeholder api, possibly as a gen_server
%       to track the last few log msgs in memory.  A client then might
%       want to do a rpc:multicall to gather all the recent log entries.

% ------------------------------------------

log_test() ->
    ok = log(?MODULE, 1, "test log"),
    ok = log(?MODULE, 2, "test log ~p ~p", [x, y]),
    ok.
