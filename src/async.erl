%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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

-export([start/1, start_many/2,
         abort/1, abort_many/1,
         send/2,
         with/2, with_many/3,
         wait/1, wait_many/1, wait_any/1,
         race/2, map/2, foreach/2,
         run_with_timeout/2]).

start(Fun) ->
    Parent = self(),
    PDict = erlang:get(),

    spawn(
      fun () ->
              async_init(Parent, PDict, Fun)
      end).

start_many(Fun, Args) ->
    [start(fun () ->
                   Fun(A)
           end) || A <- Args].

abort(Pid) ->
    abort_many([Pid]).

abort_many(Pids) ->
    misc:terminate_and_wait(shutdown, Pids).

send(Async, Msg) ->
    Async ! {'$async_msg', Msg},
    Msg.

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

%% internal
async_init(Parent, PDict, Fun) ->
    process_flag(trap_exit, true),
    MRef = erlang:monitor(process, Parent),

    maybe_register_with_parent_async(PDict),

    Reply = make_ref(),
    Async = self(),

    Child =
        spawn_link(
          fun () ->
                  erlang:put('$async', Async),

                  R = try
                          {ok, Fun()}
                      catch
                          T:E ->
                              {raised, {T, E,
                                        erlang:get_stacktrace()}}
                      end,

                  Async ! {Reply, R}
          end),

    async_loop_wait_result(MRef, Child, Reply, []).

maybe_register_with_parent_async(PDict) ->
    case lists:keyfind('$async', 1, PDict) of
        false ->
            ok;
        {_, Pid} ->
            register_with_parent_async(Pid)
    end.

register_with_parent_async(Pid) ->
    ok = call(Pid, {register_child_async, self()}).

async_loop_wait_result(ParentMRef, Child, Reply, ChildAsyncs) ->
    receive
        {'DOWN', ParentMRef, _, _, Reason} ->
            misc:terminate_and_wait(Reason, [Child | ChildAsyncs]),
            exit(Reason);
        {'EXIT', Child, Reason} ->
            exit({child_died, Reason});
        %% note, we don't assume that this comes from the parent, because we
        %% can be terminated by parent async, for example, which is not the
        %% actual parent of our process
        {'EXIT', _, Reason} ->
            misc:terminate_and_wait(Reason, [Child | ChildAsyncs]),
            exit(Reason);
        {'$async_req', From, {register_child_async, Pid}} ->
            reply(From, ok),
            async_loop_wait_result(ParentMRef, Child,
                                   Reply, [Pid | ChildAsyncs]);
        {Reply, Result0} ->
            Result = async_loop_handle_result(Result0),

            unlink(Child),
            receive
                {'EXIT', Child, _} -> ok
            after
                0 -> ok
            end,

            async_loop_with_result(ParentMRef, Result);
        {'$async_msg', Msg} ->
            Child ! Msg,
            async_loop_wait_result(ParentMRef, Child, Reply, ChildAsyncs)
    end.

async_loop_handle_result({ok, Result}) ->
    Result;
async_loop_handle_result({raised, {_T, _E, _Stack}} = Raised) ->
    exit(Raised).

async_loop_with_result(ParentMRef, Result) ->
    receive
        {'DOWN', ParentMRef, _, _, Reason} ->
            exit(Reason);
        {'EXIT', _, Reason} ->
            exit(Reason);
        {'$async_req', From, get_result} ->
            reply(From, Result);
        _ ->
            async_loop_with_result(ParentMRef, Result)
    end.

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
              receive
                  {MRef, _} ->
                      ok
              after
                  0 ->
                      ok
              end
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
