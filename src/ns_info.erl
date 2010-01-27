%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

-module(ns_info).

-export([version/0, runtime/0, basic_info/0]).

version() ->
    lists:map(fun({App, _, Version}) -> {App, Version} end,
              application:loaded_applications()).

runtime() ->
    {WallClockMSecs, _} = erlang:statistics(wall_clock),
    [{otp_release, erlang:system_info(otp_release)},
     {erl_version, erlang:system_info(version)},
     {erl_version_long, erlang:system_info(system_version)},
     {system_arch, erlang:system_info(system_architecture)},
     {localtime, erlang:localtime()},
     {memory, erlang:memory()},
     {loaded, erlang:loaded()},
     {applications, application:loaded_applications()},
     {pre_loaded, erlang:pre_loaded()},
     {process_count, erlang:system_info(process_count)},
     {process_info, erlang:system_info(procs)},
     {node, erlang:node()},
     {nodes, erlang:nodes()},
     {registered, erlang:registered()},
     {cookie, erlang:get_cookie()},
     {wordsize, erlang:system_info(wordsize)},
     {wall_clock, trunc(WallClockMSecs / 1000)}].

basic_info() ->
    {WallClockMSecs, _} = erlang:statistics(wall_clock),
    {erlang:node(),
     [{version, version()},
      {system_arch, erlang:system_info(system_architecture)},
      {wall_clock, trunc(WallClockMSecs / 1000)},
      {memory_data, memsup:get_memory_data()}]}.
