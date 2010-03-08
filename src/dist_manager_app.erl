%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(dist_manager_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _StartArgs) ->
    dist_sup:start_link().

stop(_State) ->
    ok.

