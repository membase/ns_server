%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc TEMPLATE.

-module(menelaus).
-author('Northscale <info@northscale.com>').
-export([start/0, stop/0]).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.

%% @spec start() -> ok
%% @doc Start the menelaus server.
start() ->
    menelaus_deps:ensure(),
    ensure_started(crypto),
    application:start(menelaus).

%% @spec stop() -> ok
%% @doc Stop the menelaus server.
stop() ->
    Res = application:stop(menelaus),
    application:stop(crypto),
    Res.
