-module(ns_log).

-export([log/2, log/3]).

-include_lib("eunit/include/eunit.hrl").

%% API

% A Code is an atom which should have a short module-specific prefix,
% like xy_0001, xy_0002, cfg_0099.
%
log(Code, Msg) ->
    error_logger:info_msg("~p: ~p", [Code, Msg]),
    ok.

log(Code, Fmt, Args) ->
    error_logger:info_msg("~p: " ++ Fmt, [Code | Args]),
    ok.

% TODO: Implement this placeholder api, possibly as a gen_server
%       to track the last few log msgs in memory.  A client then might
%       want to do a rpc:multicall to gather all the recent log entries.


