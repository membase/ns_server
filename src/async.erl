%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(async).

-include("cut.hrl").
-include("ns_common.hrl").

-export([start/1, start/2, start_many/2,
         perform/1, perform/2,
         abort/1, abort/2,
         abort_many/1, abort_many/2,
         send/2, adopt/1,
         with/2, with_many/3,
         wait/1, wait_many/1, wait_any/1,
         race/2, map/2, foreach/2,
         run_with_timeout/2,
         get_identity/0]).

start(Fun) ->
    start(Fun, []).

start(Fun, Opts) ->
    SpawnFun =
        case proplists:get_value(monitor, Opts, false) of
            true ->
                fun misc:spawn_monitor/1;
            false ->
                fun proc_lib:spawn/1
        end,

    Parent           = self(),
    ParentController = get_controller(),

    SpawnFun(
      fun () ->
              async_init(Parent, ParentController, Opts, Fun)
      end).

perform(Fun) ->
    perform(Fun, [monitor]).

perform(Fun, Opts) ->
    start(Fun, Opts ++ [{type, perform}]).

start_many(Fun, Args) ->
    [start(fun () ->
                   Fun(A)
           end) || A <- Args].

abort(Pid) ->
    abort_many([Pid]).

abort(Pid, Reason) ->
    abort_many([Pid], Reason).

abort_many(Pids) ->
    abort_many(Pids, shutdown).

abort_many(Pids, Reason) ->
    misc:terminate_and_wait(Reason, Pids).

send(Async, Msg) ->
    Async ! {'$async_msg', Msg},
    Msg.

adopt(Child) ->
    executor = get_role(),
    ok = call(Child, {initiate_adoption, get_controller()}).

with(AsyncBody, Fun) ->
    Async = start(AsyncBody),
    try
        Fun(Async)
    after
        abort(Async)
    end.

with_many(AsyncBody, Args, Fun) ->
    Asyncs = start_many(AsyncBody, Args),
    try
        Fun(Asyncs)
    after
        abort_many(Asyncs)
    end.

wait(Pid) ->
    call(Pid, get_result).

wait_many(Pids) ->
    call_many(Pids, get_result).

wait_any(Pids) ->
    call_any(Pids, get_result).

race(Fun1, Fun2) ->
    with(
      Fun1,
      fun (Async1) ->
              with(
                Fun2,
                fun (Async2) ->
                        case wait_any([Async1, Async2]) of
                            {Async1, R} ->
                                {left, R};
                            {Async2, R} ->
                                {right, R}
                        end
                end)
      end).

map(Fun, List) ->
    with_many(
      Fun, List,
      fun (Asyncs) ->
              Results = wait_many(Asyncs),
              [R || {_, R} <- Results]
      end).

foreach(Fun, List) ->
    with_many(
      Fun, List,
      fun (Asyncs) ->
              _ = wait_many(Asyncs),
              ok
      end).

run_with_timeout(Fun, Timeout) ->
    case race(Fun, fun () -> receive after Timeout -> timeout end end) of
        {left, R} ->
            {ok, R};
        {right, timeout} ->
            {error, timeout}
    end.

get_identity() ->
    case get_role() of
        executor ->
            Controller = get_controller(),
            true = is_pid(Controller),

            {ok, Controller};
        _ ->
            not_async
    end.

%% internal
async_init(Parent, ParentController, Opts, Fun) ->
    process_flag(trap_exit, true),
    erlang:monitor(process, Parent),

    set_role(controller),
    maybe_register_with_parent_async(ParentController),

    Reply      = make_ref(),
    Controller = self(),

    Child =
        spawn_link(
          fun () ->
                  set_role(executor),
                  set_controller(Controller),

                  To = {Controller, Reply},

                  try Fun() of
                      R ->
                          reply(To, {ok, R})
                  catch
                      T:E ->
                          Stack = erlang:get_stacktrace(),
                          reply(To, {raised, {T, E, Stack}}),
                          erlang:raise(T, E, Stack)
                  end
          end),

    MonitorPids = proplists:get_value(monitor_pids, Opts, []),
    lists:foreach(erlang:monitor(process, _), MonitorPids),

    Adopters = proplists:get_value(adopters, Opts, []),
    lists:foreach(register_for_adoption(_), Adopters),

    Type = proplists:get_value(type, Opts, wait),
    async_loop_wait_result(Type, Child, Reply, []).

maybe_register_with_parent_async(undefined) ->
    ok;
maybe_register_with_parent_async(Pid) ->
    {ok, _} = register_with_async(Pid).

register_with_async(Pid) ->
    controller = get_role(),
    {ok, _} = call(Pid, {register_child_async, self()}).

async_loop_wait_result(Type, Child, Reply, ChildAsyncs) ->
    receive
        {'DOWN', _MRef, process, _Pid, Reason} = Down ->
            maybe_log_down_message(Down),
            terminate_now(Reason, [Child | ChildAsyncs]);
        {'EXIT', Child, Reason} ->
            terminate_on_query(Type, {child_died, Reason}, ChildAsyncs);
        %% note, we don't assume that this comes from the parent, because we
        %% can be terminated by parent async, for example, which is not the
        %% actual parent of our process
        {'EXIT', _, Reason} ->
            terminate_now(Reason, [Child | ChildAsyncs]);
        {'$async_req', From, {initiate_adoption, Controller}} ->
            handle_initiate_adoption(Controller, From),
            async_loop_wait_result(Type, Child, Reply, ChildAsyncs);
        {'$async_req', From, {register_child_async, Pid}} ->
            reply(From, {ok, Child}),
            async_loop_wait_result(Type, Child, Reply, [Pid | ChildAsyncs]);
        {Reply, Result} ->
            async_loop_handle_result(Type, Child, ChildAsyncs, Result);
        {'$async_msg', Msg} ->
            Child ! Msg,
            async_loop_wait_result(Type, Child, Reply, ChildAsyncs)
    end.

terminate_now(Reason, Children) ->
    misc:terminate_and_wait(Reason, Children),
    exit(Reason).

terminate_on_query(perform, Reason, Children) ->
    terminate_now(Reason, Children);
terminate_on_query(wait, Reason, Children) ->
    misc:terminate_and_wait(Reason, Children),
    async_loop_with_result({die, Reason}).

async_loop_handle_result(Type, Child, ChildAsyncs, Result) ->
    unlink(Child),
    ?flush({'EXIT', Child, _}),

    misc:terminate_and_wait(shutdown, ChildAsyncs),

    case Type of
        perform ->
            case Result of
                {raised, {T, E, Stack}} ->
                    erlang:raise(T, E, Stack);
                {ok, _} ->
                    exit(normal)
            end;
        wait ->
            case Result of
                {ok, Success} ->
                    async_loop_with_result({reply, Success});
                {raised, _} = Raised ->
                    async_loop_with_result({die, Raised})
            end
    end.

async_loop_with_result(Result) ->
    receive
        {'DOWN', _MRef, process, _Pid, Reason} = Down ->
            maybe_log_down_message(Down),
            exit(Reason);
        {'EXIT', _, Reason} ->
            exit(Reason);
        {'$async_req', From, get_result} ->
            handle_get_result(From, Result);
        {'$async_req', From, {initiate_adoption, Controller}} ->
            handle_initiate_adoption(Controller, From),
            async_loop_with_result(Result);
        {'$async_req', From, {register_child_async, _Pid}} ->
            %% We don't expect register requests at this point, but it's
            %% possible to write a correct async that has such behavior. If we
            %% don't reply, the requesting process will have to wait till we
            %% die, which is unnecessary. So we just respond with nack to kill
            %% it quickly.
            reply(From, nack);
        {'$async_req', From, _} ->
            %% Similar logic applies to all the other requests (that actually
            %% don't exist at the moment).
            reply(From, nack);
        _ ->
            async_loop_with_result(Result)
    end.

handle_get_result(From, {reply, Result}) ->
    reply(From, Result);
handle_get_result(_From, {die, Reason}) ->
    exit(Reason).

call(Pid, Req) ->
    [{Pid, R}] = call_many([Pid], Req),
    R.

call_many(Pids, Req) ->
    PidMRefs = monitor_asyncs(Pids),
    try
        send_req_many(PidMRefs, Req),
        recv_many(PidMRefs)
    after
        demonitor_asyncs(PidMRefs)
    end.

call_any(Pids, Req) ->
    PidMRefs = monitor_asyncs(Pids),
    try
        send_req_many(PidMRefs, Req),
        recv_any(PidMRefs)
    after
        Pids = demonitor_asyncs(PidMRefs),
        abort_many(Pids),
        drop_extra_resps(PidMRefs)
    end.

drop_extra_resps(PidMRefs) ->
    lists:foreach(
      fun ({_, MRef}) ->
              ?flush({MRef, _})
      end, PidMRefs).

reply({Pid, Tag}, Reply) ->
    Pid ! {Tag, Reply}.

monitor_asyncs(Pids) ->
    [{Pid, erlang:monitor(process, Pid)} || Pid <- Pids].

demonitor_asyncs(PidMRefs) ->
    lists:map(
      fun ({Pid, MRef}) ->
              erlang:demonitor(MRef, [flush]),
              Pid
      end, PidMRefs).

send_req(Pid, MRef, Req) ->
    Pid ! {'$async_req', {self(), MRef}, Req}.

send_req_many(PidMRefs, Req) ->
    lists:foreach(
      fun ({Pid, MRef}) ->
              send_req(Pid, MRef, Req)
      end, PidMRefs).

recv_resp(MRef) ->
    receive
        {MRef, R} ->
            R;
        {'DOWN', MRef, _, _, Reason} ->
            recv_resp_handle_down(Reason)
    end.

recv_resp_handle_down({raised, {T, E, Stack}}) ->
    erlang:raise(T, E, Stack);
recv_resp_handle_down(Reason) ->
    exit(Reason).

recv_many([]) ->
    [];
recv_many([{Pid, MRef} | Rest]) ->
    [{Pid, recv_resp(MRef)} | recv_many(Rest)].

recv_any(PidMRefs) ->
    recv_any_loop(PidMRefs, []).

recv_any_loop(PidMRefs, PendingMsgs) ->
    receive
        {Ref, R} = Msg when is_reference(Ref) ->
            case lists:keyfind(Ref, 2, PidMRefs) of
                {Pid, Ref} ->
                    recv_any_loop_resend_pending(PendingMsgs),
                    {Pid, R};
                false ->
                    recv_any_loop(PidMRefs, [Msg | PendingMsgs])
            end;
        {'DOWN', Ref, _, _, Reason} = Msg ->
            case lists:keymember(Ref, 2, PidMRefs) of
                true ->
                    recv_any_loop_resend_pending(PendingMsgs),
                    recv_resp_handle_down(Reason);
                false ->
                    recv_any_loop(PidMRefs, [Msg | PendingMsgs])
            end
    end.

recv_any_loop_resend_pending(PendingMsgs) ->
    lists:foreach(
      fun (Msg) ->
              self() ! Msg
      end, lists:reverse(PendingMsgs)).

set_role(Role) ->
    erlang:put('$async_role', Role).

get_role() ->
    erlang:get('$async_role').

set_controller(Pid) when is_pid(Pid) ->
    executor = get_role(),
    erlang:put('$async_controller', Pid).

get_controller() ->
    erlang:get('$async_controller').

handle_initiate_adoption(Controller, From) ->
    register_for_adoption(Controller),
    reply(From, ok).

register_for_adoption(Controller) ->
    {ok, Executor} = register_with_async(Controller),
    erlang:monitor(process, Executor).

maybe_log_down_message({'DOWN', _MRef, process, Pid, Reason}) ->
    case misc:is_normal_termination(Reason) of
        true ->
            ok;
        false ->
            ?log_warning("Monitored process ~p "
                         "terminated abnormally (reason = ~p)", [Pid, Reason])
    end.
