-module(ns_babysitter_bootstrap).

-export([start/0, stop/0, get_quick_stop/0, remote_stop/1, override_resolver/0]).

-include("ns_common.hrl").

start() ->
    try
        ok = application:start(ale),
        ok = application:start(sasl),
        ok = application:start(ns_babysitter, permanent),
        (catch ?log_info("~s: babysitter has started", [os:getpid()]))
    catch T:E ->
            timer:sleep(500),
            erlang:T(E)
    end.

stop() ->
    (catch ?log_info("~s: got shutdown request. Terminating.", [os:getpid()])),
    application:stop(ns_babysitter),
    ale:sync_all_sinks(),
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
