%% @author Northscale <info@northscale.com>
%% @copyright 2009 Northscale.

%% @doc TEMPLATE.

-module(menelaus_server).
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
%% @doc Start the menelaus_server server.
start() ->
    menelaus_server_deps:ensure(),
    ensure_started(crypto),
    application:start(menelaus_server).

%% @spec stop() -> ok
%% @doc Stop the menelaus_server server.
stop() ->
    Res = application:stop(menelaus_server),
    application:stop(crypto),
    Res.
