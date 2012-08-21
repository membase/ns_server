-module(ns_memcached_log_rotator).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {dir, prefix}).

log_params() ->
    Conf = ns_config:get(),
    {ns_config:search_node_prop(Conf, memcached, log_generations),
     ns_config:search_node_prop(Conf, memcached, log_rotation_period)}.

start_link() ->
    Conf = ns_config:get(),
    Dir = ns_config:search_node_prop(Conf, memcached, log_path),
    Prefix = ns_config:search_node_prop(Conf, memcached, log_prefix),
    gen_server:start_link(?MODULE, [Dir, Prefix], []).

init([Dir, Prefix]) ->
    {_Generations, Period} = log_params(),
    ?log_info("Starting log rotator on ~p/~p* with an initial period of ~pms",
              [Dir, Prefix, Period]),
    {ok, #state{dir=Dir, prefix=Prefix}, Period}.

handle_call(Request, From, State) ->
    ?log_warning("Unexpected handle_call(~p, ~p, ~p)", [Request, From, State]),
    exit(invalid_message).

handle_cast(Msg, State) ->
    ?log_warning("Unexpected handle_cast(~p, ~p)", [Msg, State]),
    exit(invalid_message).

handle_info(timeout, State) ->
    {Generations, Period} = log_params(),
    N = file_util:remove(State#state.dir, State#state.prefix, Generations),
    ?log_info("Removed ~p ~p log files from ~p (retaining up to ~p)",
              [N, State#state.prefix, State#state.dir, Generations]),
    {noreply, State, Period}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
