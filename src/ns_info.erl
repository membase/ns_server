%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

-module(ns_info).

-export([version_path/0, version/0, runtime/0]).

version_path() ->
    filename:join(filename:dirname(
                    filename:absname(code:which(?MODULE))),
                  atom_to_list(?MODULE) ++ ".version").

version() ->
    Path = version_path(),
    Info = case file:consult(Path) of
        {ok, X}         -> X;
        {error, enoent} -> []
    end,
    Info.

runtime() ->
    [{otp_release, erlang:system_info(otp_release)},
     {erl_version, erlang:system_info(version)},
     {erl_version_long, erlang:system_info(system_version)},
     {system_arch, erlang:system_info(system_architecture)},
     {localtime, erlang:localtime()},
     {memory, erlang:memory()},
     {loaded, erlang:loaded()},
     {applications, application:which_applications()},
     {pre_loaded, erlang:pre_loaded()},
     {process_count, erlang:system_info(process_count)},
     {process_info, erlang:system_info(procs)},
     {nodes, erlang:nodes()},
     {registered, erlang:registered()},
     {cookie, erlang:get_cookie()},
     {wordsize, erlang:system_info(wordsize)}].

