-module(ns_log).

-export([log/2, log/3]).

-include_lib("eunit/include/eunit.hrl").

%% API

% A Code is an atom which should have a short module-specific prefix,
% like xy_0001, xy_0002, cfg_0099.
%
log(_Code, _Msg) ->
    ok.

log(_Code, _Fmt, _Args) ->
    ok.

% TODO: Implement this placeholder api.
