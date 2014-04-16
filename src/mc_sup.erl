-module(mc_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

start_link() ->
    PortNum = ns_config:search_node_prop(ns_config:get(), memcached, mccouch_port),
    supervisor:start_link({local, ?MODULE}, ?MODULE, [PortNum]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([PortNum]) ->
    RestartStrategy = rest_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    ConnSup = {mc_conn_sup, {mc_conn_sup, start_link, []},
               permanent, brutal_kill, supervisor, dynamic},

    TcpListener = {mc_tcp_listener, {mc_tcp_listener, start_link, [PortNum]},
                   permanent, brutal_kill, worker, [mc_tcp_listener]},

    {ok, {SupFlags, [ConnSup, TcpListener]}}.
