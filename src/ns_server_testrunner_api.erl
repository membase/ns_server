-module(ns_server_testrunner_api).

-compile(export_all).

restart_memcached(Timeout) ->
    {ok, _} = rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, restart_port_by_name, [memcached], Timeout).

kill_memcached(Timeout) ->
    Pid = rpc:call(ns_server:get_babysitter_node(), ns_child_ports_sup, find_port, [memcached]),
    Pid ! {send_to_port, <<"die!\n">>},
    ok = misc:wait_for_process(Pid, Timeout).

eval_string(String) ->
    {value, Value, _} = eshell:eval(String, erl_eval:new_bindings()),
    Value.

%% without this API we're forced to rpc call into erlang:apply and
%% pass erl_eval-wrapped function literals which doesn't work across
%% different erlang versions
eval_string_multi(String, Nodes, Timeout) ->
    rpc:call(Nodes, ns_server_testrunner_api, eval_string, String, Timeout).
