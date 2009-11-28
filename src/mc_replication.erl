-module(mc_replication).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

send(Addrs, Out, Cmd, CmdArgs,
     ResponseFilter, ResponseModule, undefined) ->
    mc_downstream:send(Addrs, Out, Cmd, CmdArgs,
                       ResponseFilter, ResponseModule);

send(Addrs, Out, Cmd, CmdArgs,
     ResponseFilter, ResponseModule, _Policy) ->
    mc_downstream:send(Addrs, Out, Cmd, CmdArgs,
                       ResponseFilter, ResponseModule).

