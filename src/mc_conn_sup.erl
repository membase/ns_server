-module(mc_conn_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-export([start_connection/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{simple_one_for_one, 0, 1},
          [{mc_connection, {mc_connection, start_link, []},
            temporary, brutal_kill, worker, dynamic}]}}.

start_connection(Socket) ->
    {ok, Pid} = supervisor:start_child(?MODULE, [Socket]),
    ok = gen_tcp:controlling_process(Socket, Pid),
    Pid.
