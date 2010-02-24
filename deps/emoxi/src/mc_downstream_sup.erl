-module(mc_downstream_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
        add_downstream/2, rm_downstream/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one, 10, 10}, []}}.

add_downstream(Addr, Timeout) ->
    supervisor:start_child(?MODULE,
                           {Addr,
                            {mc_downstream_conn, start_link, [Addr, Timeout]},
                            permanent, 10, worker, [mc_downstream_conn]}).

rm_downstream(Addr) ->
    ok = supervisor:terminate_child(?MODULE, Addr),
    ok = supervisor:delete_child(?MODULE, Addr).
