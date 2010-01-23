%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Supervisor for the menelaus application.

-module(menelaus_sup).
-author('Northscale <info@northscale.com>').

-behaviour(supervisor).

%% External exports
-export([start_link/0, upgrade/0]).

%% supervisor callbacks
-export([init/1]).

%% @spec start_link() -> ServerRet
%% @doc API for starting the supervisor.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @spec upgrade() -> ok
%% @doc Add processes if necessary.
upgrade() ->
    {ok, {_, Specs}} = init([]),

    Old = sets:from_list(
            [Name || {Name, _, _, _} <- supervisor:which_children(?MODULE)]),
    New = sets:from_list([Name || {Name, _, _, _, _, _} <- Specs]),
    Kill = sets:subtract(Old, New),

    sets:fold(fun (Id, ok) ->
                      supervisor:terminate_child(?MODULE, Id),
                      supervisor:delete_child(?MODULE, Id),
                      ok
              end, ok, Kill),

    [supervisor:start_child(?MODULE, Spec) || Spec <- Specs],
    ok.

%% @spec init([]) -> SupervisorTree
%% @doc supervisor callback.
init([]) ->
    Web = {menelaus_web,
           {menelaus_web, start_link, []},
           permanent, 5000, worker, dynamic},

    WebEvent = {menelaus_event,
                {menelaus_event, start_link, []},
                transient, 5000, worker, dynamic},

    SimpleCache = {simple_cache,
                   {simple_cache, start_link, []},
                   permanent, 5000, worker, dynamic},

    Processes = [Web, WebEvent, SimpleCache],
    {ok, {{one_for_one, 10, 10}, Processes}}.

