%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(ns_bootstrap).

-export([start/0, override_resolver/0]).

start() ->
    ok = application:start(sasl),
    ok = application:start(dist_manager),
    ok = application:start(ns_server),
    ok = gen_event:add_handler(ns_network_events,
                               ns_address_change_handler, []).

override_resolver() ->
    inet_db:set_lookup([file, dns]),
    start().
