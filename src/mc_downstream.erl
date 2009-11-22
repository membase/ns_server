-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% API for downstream.

%% TODO: A proper implementation.
%% TODO: Consider replacing implementation with gen_server.

monitor(Addr, CallerPid, _SomeFlag) ->
    todo.

send(Addr, CallerPid, ErrMsg, SendCmd, CallerPid2, ResponseFilter,
     ClientProtocolModule, Cmd, CmdArgs, NotifyData) ->
    todo.
