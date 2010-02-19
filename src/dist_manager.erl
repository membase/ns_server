% Distributed erlang configuration and management

-module(dist_manager).

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([network_change/0]).

-record(state, {self_started}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    gen_event:add_handler(ns_network_events,
                          dist_manager_informer, []),
    {ok, #state{self_started=bringup()}}.

%% There are only two valid cases here:
%% 1. Successfully started
decode_status({ok, _Pid}) ->
    true;
%% 2. Already initialized (via -name or -sname)
decode_status({error, {{already_started, _Pid}, _Stack}}) ->
    false.

%% Bring up distributed erlang.
bringup() ->
    MyAddress = net_watcher:current_address(),
    MyNodeName = list_to_atom("ns1@" ++ MyAddress),
    Rv = decode_status(net_kernel:start([MyNodeName, longnames])),
    gen_event:notify(ns_network_events, {self_up, node()}),
    Rv.

%% Tear down distributed erlang.
teardown() ->
    ok = net_kernel:stop(),
    gen_event:notify(ns_network_events, self_down).

net_change(State) ->
    case State#state.self_started of
        true ->
            teardown(),
            bringup();
        _ ->
            error_logger:info_msg(
              "Ignoring net change, manually configured.~n")
    end.

handle_call(_Request, _From, _State) ->
    exit(unhandled).

handle_cast(network_change, State) ->
    net_change(State),
    {noreply, State}.

handle_info(_Info, _State) ->
    exit(unhandled).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

network_change() ->
    gen_server:cast(?MODULE, network_change).
