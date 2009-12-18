%% @author Northscale <info@northscale.com>
%% @copyright 2009 Northscale.

%% @doc Callbacks for the menelaus application.

-module(menelaus_app).
-author('Northscale <info@northscale.com>').

-behaviour(application).
-export([start/2,stop/1]).


%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for menelaus.
start(_Type, _StartArgs) ->
    menelaus_deps:ensure(),
    menelaus_sup:start_link().

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for menelaus.
stop(_State) ->
    ok.
