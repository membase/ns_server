-module(ns_port_init).

-behaviour(gen_event).

-export([start/0]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

% Noop process to get initialized in the supervision tree.
start() ->
    {ok, spawn_link(fun() ->
                            gen_event:add_handler(ns_config_events, ?MODULE, ignored)
                    end)}.

init(ignored) ->
    {value, PortServers} = ns_config:search(ns_config:get(), port_servers),
    error_logger:info_msg("Initializing ports: ~p~n", [PortServers]),
    lists:foreach(fun launch_port/1, PortServers),
    {ok, #state{}, hibernate}.

handle_event({port_servers, List}, State) ->
    % TODO: Port server stuff
    error_logger:info_msg("Changing port servers: ~p...~n", [List]),
    {ok, State, hibernate};
handle_event(_Stuff, State) ->
    {ok, State, hibernate}.

handle_call(_Request, State) ->
    Reply = ok,
    {ok, Reply, State, hibernate}.

handle_info(_Info, State) ->
    {ok, State, hibernate}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


launch_port({Name, Path, Args}) ->
    error_logger:info_msg("   Starting one port:  ~p ~p ~p~n",
                          [Name, Path, Args]),
    ns_port_sup:launch_port(Name, Path, Args).
