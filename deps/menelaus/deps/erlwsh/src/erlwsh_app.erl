%% @author author <author@example.com>
%% @copyright YYYY author.

%% @doc Callbacks for the erlwsh application.

-module(erlwsh_app).
-author('author <author@example.com>').

-behaviour(application).
-export([start/2,stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for erlwsh.
start(_Type, _StartArgs) ->
    erlwsh_deps:ensure(),
    erlwsh_sup:start_link().

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for erlwsh.
stop(_State) ->
    ok.
