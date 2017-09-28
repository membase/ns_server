-module(ns_babysitter_bootstrap).

-export([start/0, stop/0, get_quick_stop/0, remote_stop/1, override_resolver/0]).
-export([ipv6_from_static_config/1]).

-include("ns_common.hrl").

start() ->
    try
        ok = application:start(ale),
        ok = application:start(sasl),
        ok = application:start(ns_babysitter, permanent),
        (catch ?log_info("~s: babysitter has started", [os:getpid()])),
        ns_babysitter:make_pidfile()
    catch T:E ->
            timer:sleep(500),
            erlang:T(E)
    end.

stop() ->
    (catch ?log_info("~s: got shutdown request. Terminating.", [os:getpid()])),
    application:stop(ns_babysitter),
    ale:sync_all_sinks(),
    ns_babysitter:delete_pidfile(),
    init:stop().

remote_stop(Node) ->
    RV = rpc:call(Node, ns_babysitter_bootstrap, stop, []),
    ExitStatus = case RV of
                     ok -> 0;
                     Other ->
                         io:format("NOTE: shutdown failed~n~p~n", [Other]),
                         1
                 end,
    init:stop(ExitStatus).

get_quick_stop() ->
    fun quick_stop/0.

quick_stop() ->
    application:set_env(ns_babysitter, port_shutdown_command, "die!"),
    stop().


override_resolver() ->
    inet_db:set_lookup([file, dns]),
    start().

%% This function will be called by the init script to determine
%% the networking mode to start with.
ipv6_from_static_config(StaticConfigPath) ->
    Terms = case file:consult(StaticConfigPath) of
                {ok, T} when is_list(T) ->
                    T;
                Error ->
                    {error, Error}
            end,

    ExitStatus = case Terms of
                     {error, _} ->
                         io:format("Failed to read static config: ~p. "
                                   "It must be a readable file with list of pairs.",
                                   [StaticConfigPath]),
                         1;
                     _ ->
                         case [true || {K, V} <- Terms, K =:= ipv6 andalso V =:= true] of
                             [true] ->
                                 io:format("true");
                             _ ->
                                 io:format("false")
                         end,

                         0
                 end,

    init:stop(ExitStatus).
