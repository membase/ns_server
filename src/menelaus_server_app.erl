%% @author Northscale <info@northscale.com>
%% @copyright 2009 Northscale.

%% @doc Callbacks for the menelaus_server application.

-module(menelaus_server_app).
-author('Northscale <info@northscale.com>').

-behaviour(application).
-export([start/2,stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for menelaus_server.
start(_Type, _StartArgs) ->
    menelaus_server_deps:ensure(),
    menelaus_server_sup:start_link().

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for menelaus_server.
stop(_State) ->
    ok.
