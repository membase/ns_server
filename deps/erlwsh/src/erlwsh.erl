%% @author author <author@example.com>
%% @copyright YYYY author.

%% @doc TEMPLATE.

-module(erlwsh).
-author('author <author@example.com>').
-export([start/0, stop/0]).

ensure_started(App) ->
    case application:start(App) of
        ok ->
            ok;
        {error, {already_started, App}} ->
            ok
    end.
        
%% @spec start() -> ok
%% @doc Start the erlwsh server.
start() ->
    erlwsh_deps:ensure(),
    ensure_started(crypto),
    application:start(erlwsh).

%% @spec stop() -> ok
%% @doc Stop the erlwsh server.
stop() ->
    Res = application:stop(erlwsh),
    application:stop(crypto),
    Res.
