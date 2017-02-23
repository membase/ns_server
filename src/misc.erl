% Copyright (c) 2009-2016, Couchbase, Inc.
% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
%
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% * Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
% * Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
% * Neither the name of Powerset, Inc nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
% COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(misc).

-include("ns_common.hrl").
-include_lib("kernel/include/file.hrl").

-include("triq.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

shuffle(List) when is_list(List) ->
    [N || {_R, N} <- lists:keysort(1, [{random:uniform(), X} || X <- List])].

get_days_list() ->
    ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].

% formats time (see erlang:localtime/0) as ISO-8601 text
iso_8601_fmt({{Year,Month,Day},{Hour,Min,Sec}}) ->
    io_lib:format("~4.10.0B-~2.10.0B-~2.10.0B ~2.10.0B:~2.10.0B:~2.10.0B",
                  [Year, Month, Day, Hour, Min, Sec]).

%% applies (catch Fun(X)) for each element of list in parallel. If
%% execution takes longer than given Timeout it'll exit with reason
%% timeout (which is consistent with behavior of gen_XXX:call
%% modules).  Care is taken to not leave any messages in calling
%% process mailbox and to correctly shutdown any worker processes
%% if/when calling process is killed.
-spec parallel_map(fun((any()) -> any()), [any()], non_neg_integer() | infinity) -> [any()].
parallel_map(Fun, List, Timeout) when is_list(List) andalso is_function(Fun) ->
    case async:run_with_timeout(
           fun () ->
                   async:map(Fun, List)
           end, Timeout) of
        {ok, R} ->
            R;
        {error, timeout} ->
            exit(timeout)
    end.

gather_dir_info(Name) ->
    case file:list_dir(Name) of
        {ok, Filenames} ->
            [gather_link_info(filename:join(Name, N)) || N <- Filenames];
        Error ->
            Error
    end.

gather_link_info(Name) ->
    case file:read_link_info(Name) of
        {ok, Info} ->
            case Info#file_info.type of
                directory ->
                    {Name, Info, gather_dir_info(Name)};
                _ ->
                    {Name, Info}
            end;
        Error ->
            {Name, Error}
    end.

rm_rf(Name) when is_list(Name) ->
  case rm_rf_is_dir(Name) of
      {ok, false} ->
          file:delete(Name);
      {ok, true} ->
          case file:list_dir(Name) of
              {ok, Filenames} ->
                  case rm_rf_loop(Name, Filenames) of
                      ok ->
                          case file:del_dir(Name) of
                              ok ->
                                  ok;
                              {error, enoent} ->
                                  ok;
                              Error ->
                                  ?log_warning("Cannot delete ~p: ~p~nDir info: ~p",
                                               [Name, Error, gather_dir_info(Name)]),
                                  Error
                          end;
                      Error ->
                          Error
                  end;
              {error, enoent} ->
                  ok;
              {error, Reason} = Error ->
                  ?log_warning("rm_rf failed because ~p", [Reason]),
                  Error
          end;
      {error, enoent} ->
          ok;
      Error ->
          ?log_warning("stat on ~s failed: ~p", [Name, Error]),
          Error
  end.

rm_rf_is_dir(Name) ->
    case file:read_link_info(Name) of
        {ok, Info} ->
            {ok, Info#file_info.type =:= directory};
        Error ->
            Error
    end.

rm_rf_loop(_DirName, []) ->
    ok;
rm_rf_loop(DirName, [F | Files]) ->
    FileName = filename:join(DirName, F),
    case rm_rf(FileName) of
        ok ->
            rm_rf_loop(DirName, Files);
        {error, enoent} ->
            rm_rf_loop(DirName, Files);
        Error ->
            ?log_warning("Cannot delete ~p: ~p", [FileName, Error]),
            Error
    end.

rand_str(N) ->
  lists:map(fun(_I) ->
      random:uniform(26) + $a - 1
    end, lists:seq(1,N)).

nthreplace(N, E, List) ->
  lists:sublist(List, N-1) ++ [E] ++ lists:nthtail(N, List).

ceiling(X) ->
  T = erlang:trunc(X),
  case (X - T) of
    Neg when Neg < 0 -> T;
    Pos when Pos > 0 -> T + 1;
    _ -> T
  end.

position(Predicate, List) when is_function(Predicate) ->
  position(Predicate, List, 1);

position(E, List) ->
  position(E, List, 1).

position(Predicate, [], _N) when is_function(Predicate) -> false;

position(Predicate, [E|List], N) when is_function(Predicate) ->
  case Predicate(E) of
    true -> N;
    false -> position(Predicate, List, N+1)
  end;

position(_, [], _) -> false;

position(E, [E|_List], N) -> N;

position(E, [_|List], N) -> position(E, List, N+1).

now_int()   -> time_to_epoch_int(now()).
now_float() -> time_to_epoch_float(now()).

time_to_epoch_int(Time) when is_integer(Time) or is_float(Time) ->
  Time;

time_to_epoch_int({Mega,Sec,_}) ->
  Mega * 1000000 + Sec.

time_to_epoch_ms_int({Mega,Sec,Micro}) ->
  (Mega * 1000000 + Sec) * 1000 + (Micro div 1000).

time_to_epoch_float(Time) when is_integer(Time) or is_float(Time) ->
  Time;

time_to_epoch_float({Mega,Sec,Micro}) ->
  Mega * 1000000 + Sec + Micro / 1000000;

time_to_epoch_float(_) ->
  undefined.

now_int_to_now(Time) when is_integer(Time) ->
    epoch_to_time(Time * 1000 * 1000000).

epoch_to_time(Nano) ->
    Micro = Nano div 1000,
    Sec = Micro div 1000000,
    Mega = Sec div 1000000,
    {Mega, Sec - Mega * 1000000, Micro - Sec * 1000000}.

msecs_to_usecs(MilliSec) ->
    MilliSec * 1000.

% Returns just the node name string that's before the '@' char.
% For example, returns "test" instead of "test@myhost.com".
%
node_name_short() ->
    node_name_short(node()).

node_name_short(Node) ->
    [NodeName | _] = string:tokens(atom_to_list(Node), "@"),
    NodeName.

% Node is an atom like some_name@host.foo.bar.com

node_name_host(Node) ->
    [Name, Host | _] = string:tokens(atom_to_list(Node), "@"),
    {Name, Host}.

% Get an environment variable value or return a default value
getenv_int(VariableName, DefaultValue) ->
    case (catch list_to_integer(os:getenv(VariableName))) of
        EnvBuckets when is_integer(EnvBuckets) -> EnvBuckets;
        _ -> DefaultValue
    end.

% Get an application environment variable, or a defualt value.
get_env_default(Var, Def) ->
    case application:get_env(Var) of
        {ok, Value} -> Value;
        undefined -> Def
    end.

get_env_default(App, Var, Def) ->
    case application:get_env(App, Var) of
        {ok, Value} ->
            Value;
        undefined ->
            Def
    end.

make_pidfile() ->
    case application:get_env(pidfile) of
        {ok, PidFile} -> make_pidfile(PidFile);
        X -> X
    end.

make_pidfile(PidFile) ->
    Pid = os:getpid(),
    %% Pid is a string representation of the process id, so we append
    %% a newline to the end.
    ok = misc:write_file(PidFile, list_to_binary(Pid ++ "\n")),
    ok.

ping_jointo() ->
    case application:get_env(jointo) of
        {ok, NodeName} -> ping_jointo(NodeName);
        X -> X
    end.

ping_jointo(NodeName) ->
    ?log_debug("attempting to contact ~p", [NodeName]),
    case net_adm:ping(NodeName) of
        pong -> ?log_debug("connected to ~p", [NodeName]);
        pang -> {error, io_lib:format("could not ping ~p~n", [NodeName])}
    end.

%% http://github.com/joearms/elib1/blob/master/lib/src/elib1_misc.erl#L1367

%%----------------------------------------------------------------------
%% @doc remove leading and trailing white space from a string.

-spec trim(string()) -> string().

trim(S) ->
    remove_leading_and_trailing_whitespace(S).

trim_test() ->
    "abc" = trim("    abc   ").

%%----------------------------------------------------------------------
%% @doc remove leading and trailing white space from a string.

-spec remove_leading_and_trailing_whitespace(string()) -> string().

remove_leading_and_trailing_whitespace(X) ->
    remove_leading_whitespace(remove_trailing_whitespace(X)).

remove_leading_and_trailing_whitespace_test() ->
    "abc" = remove_leading_and_trailing_whitespace("\r\t  \n \s  abc").

%%----------------------------------------------------------------------
%% @doc remove leading white space from a string.

-spec remove_leading_whitespace(string()) -> string().

remove_leading_whitespace([$\n|T]) -> remove_leading_whitespace(T);
remove_leading_whitespace([$\r|T]) -> remove_leading_whitespace(T);
remove_leading_whitespace([$\s|T]) -> remove_leading_whitespace(T);
remove_leading_whitespace([$\t|T]) -> remove_leading_whitespace(T);
remove_leading_whitespace(X) -> X.

%%----------------------------------------------------------------------
%% @doc remove trailing white space from a string.

-spec remove_trailing_whitespace(string()) -> string().

remove_trailing_whitespace(X) ->
    lists:reverse(remove_leading_whitespace(lists:reverse(X))).

%% Wait for a process.

wait_for_process(PidOrName, Timeout) ->
    MRef = erlang:monitor(process, PidOrName),
    receive
        {'DOWN', MRef, process, _, _Reason} ->
            ok
    after Timeout ->
            erlang:demonitor(MRef, [flush]),
            {error, timeout}
    end.

wait_for_process_test_() ->
    {spawn,
     fun () ->
             %% Normal
             ok = wait_for_process(spawn(fun() -> ok end), 100),
             %% Timeout
             {error, timeout} = wait_for_process(spawn(fun() ->
                                                               timer:sleep(100), ok end),
                                                 1),
             %% Process that exited before we went.
             Pid = spawn(fun() -> ok end),
             ok = wait_for_process(Pid, 100),
             ok = wait_for_process(Pid, 100)
     end}.

-spec terminate_and_wait(Reason :: term(), Processes :: pid() | [pid()]) -> ok.
terminate_and_wait(Reason, Process) when is_pid(Process) ->
    terminate_and_wait(Reason, [Process]);
terminate_and_wait(Reason, Processes) ->
    RealReason = case Reason of
                     normal -> shutdown;
                     _ -> Reason
                 end,
    [(catch erlang:exit(P, RealReason)) || P <- Processes],
    [misc:wait_for_process(P, infinity) || P <- Processes],
    ok.

-define(WAIT_FOR_NAME_SLEEP, 200).

%% waits until given name is globally registered. I.e. until calling
%% {global, Name} starts working
wait_for_global_name(Name) ->
    Timeout = ns_config:get_timeout(wait_for_global_name, 20000),
    case do_wait_for_global_name(Name, Timeout) of
        ok ->
            ok;
        failed ->
            case ns_config:search(ns_config:latest(), enable_global_workaround, true) of
                true ->
                    case try_apply_global_workaround(Name) of
                        ok ->
                            do_wait_for_global_name(Name, Timeout);
                        failed ->
                            failed
                    end;
                false ->
                    failed
            end
    end.

try_apply_global_workaround(Name) ->
    KnownNodes0 = gen_server:call(global_name_server, get_known),
    SyncedNodes0 = gen_server:call(global_name_server, get_synced),

    KnownNodes = ordsets:from_list(KnownNodes0),
    SyncedNodes = ordsets:from_list(SyncedNodes0),

    Unsynced = ordsets:subtract(KnownNodes, SyncedNodes),
    case Unsynced =:= ordsets:new() of
        true ->
            failed;
        false ->
            ?log_debug("Found unsynced nodes ~p while looking up ~p. "
                       "Trying to work around.", [Unsynced, Name]),
            apply_global_workaround(ordsets:to_list(Unsynced))
    end.

apply_global_workaround(Nodes) ->
    lists:foreach(
      fun (N) ->
              erlang:disconnect_node(N),
              net_adm:ping(N)
      end, Nodes).

do_wait_for_global_name(Name, TimeoutMillis) ->
    wait_for_name({global, Name}, TimeoutMillis).

-ifdef(EUNIT).
wait_for_global_name_test_() ->
    {setup, fun wait_for_global_name_test_setup/0, fun wait_for_global_name_test_teardown/1,
     [fun do_test_wait_for_global_name/0]}.

wait_for_global_name_test_setup() ->
    CodePath = code:get_path(),

    {TestNode, Host0} = misc:node_name_host(node()),
    Host = list_to_atom(Host0),

    lists:map(
      fun (N) ->
              FullName = list_to_atom(atom_to_list(N) ++ "-" ++ TestNode),
              {ok, Node} = slave:start(Host, FullName),
              true = rpc:call(Node, code, set_path, [CodePath]),
              Node
      end, [a, b]).

wait_for_global_name_test_teardown(Nodes) ->
    lists:foreach(
      fun (Node) ->
              ok = slave:stop(Node)
      end, Nodes).

wait_for_global_name_test_register() ->
    global:register_name(?MODULE, whereis(global_name_server)).

do_test_wait_for_global_name() ->
    [A, B] = nodes(),

    yes = rpc:call(A, misc, wait_for_global_name_test_register, []),

    ok = rpc:call(B, misc, do_wait_for_global_name, [?MODULE, 1000]),

    true = rpc:call(B, erlang, disconnect_node, [A]),
    failed = rpc:call(B, misc, do_wait_for_global_name, [?MODULE, 1000]),

    ok = rpc:call(B, misc, apply_global_workaround, [[A]]),
    ok = rpc:call(B, misc, do_wait_for_global_name, [?MODULE, 2000]).
-endif.

wait_for_local_name(Name, TimeoutMillis) ->
    wait_for_name({local, Name}, TimeoutMillis).

wait_for_name(Name, TimeoutMillis) ->
    Tries = (TimeoutMillis + ?WAIT_FOR_NAME_SLEEP-1) div ?WAIT_FOR_NAME_SLEEP,
    wait_for_name_loop(Name, Tries).

wait_for_name_loop(Name, 0) ->
    case is_pid(whereis_name(Name)) of
        true ->
            ok;
        _ -> failed
    end;
wait_for_name_loop(Name, TriesLeft) ->
    case is_pid(whereis_name(Name)) of
        true ->
            ok;
        false ->
            timer:sleep(?WAIT_FOR_NAME_SLEEP),
            wait_for_name_loop(Name, TriesLeft-1)
    end.

whereis_name({global, Name}) ->
    global:whereis_name(Name);
whereis_name({local, Name}) ->
    erlang:whereis(Name).

%% Like proc_lib:start_link but allows to specify a node to spawn a process on.
-spec start_link(node(), module(), atom(), [any()]) -> any() | {error, term()}.
start_link(Node, M, F, A)
  when is_atom(Node), is_atom(M), is_atom(F), is_list(A) ->
    Pid = proc_lib:spawn_link(Node, M, F, A),
    sync_wait(Pid).

%% turns _this_ process into gen_server loop. Initializing and
%% registering it properly.
turn_into_gen_server({local, Name}, Mod, Args, GenServerOpts) ->
    erlang:register(Name, self()),
    {ok, State} = Mod:init(Args),
    proc_lib:init_ack({ok, self()}),
    gen_server:enter_loop(Mod, GenServerOpts, State, {local, Name}).

sync_wait(Pid) ->
    receive
        {ack, Pid, Return} ->
            Return;
        {'EXIT', Pid, Reason} ->
            {error, Reason}
    end.

poll_for_condition_rec(Condition, _Sleep, 0) ->
    case Condition() of
        false -> timeout;
        Ret -> Ret
    end;
poll_for_condition_rec(Condition, Sleep, infinity) ->
    case Condition() of
        false ->
            timer:sleep(Sleep),
            poll_for_condition_rec(Condition, Sleep, infinity);
        Ret -> Ret
    end;
poll_for_condition_rec(Condition, Sleep, Counter) ->
    case Condition() of
        false ->
            timer:sleep(Sleep),
            poll_for_condition_rec(Condition, Sleep, Counter-1);
        Ret -> Ret
    end.

poll_for_condition(Condition, Timeout, Sleep) ->
    Times = case Timeout of
                infinity ->
                    infinity;
                _ ->
                    (Timeout + Sleep - 1) div Sleep
            end,
    poll_for_condition_rec(Condition, Sleep, Times).

poll_for_condition_test() ->
    true = poll_for_condition(fun () -> true end, 0, 10),
    timeout = poll_for_condition(fun () -> false end, 100, 10),
    Ref = make_ref(),
    self() ! {Ref, 0},
    Fun  = fun() ->
                   Counter = receive
                                 {Ref, C} -> R = C + 1,
                                             self() ! {Ref, R},
                                             R
                             after 0 ->
                                 erlang:error(should_not_happen)
                             end,
                   Counter > 5
           end,
    true = poll_for_condition(Fun, 300, 10),
    receive
        {Ref, _} -> ok
    after 0 ->
            erlang:error(should_not_happen)
    end.


%% Remove matching messages from the inbox.
%% Returns a count of messages removed.

flush(Msg) -> flush(Msg, 0).

flush(Msg, N) ->
    receive
        Msg ->
            flush(Msg, N+1)
    after 0 ->
            N
    end.


%% You know, like in Python
enumerate(List) ->
    enumerate(List, 1).

enumerate([H|T], Start) ->
    [{Start, H}|enumerate(T, Start + 1)];
enumerate([], _) ->
    [].


%% Equivalent of sort|uniq -c
uniqc(List) ->
    uniqc(List, 1, []).

uniqc([], _, Acc) ->
    lists:reverse(Acc);
uniqc([H], Count, Acc) ->
    uniqc([], 0, [{H, Count}|Acc]);
uniqc([H,H|T], Count, Acc) ->
    uniqc([H|T], Count+1, Acc);
uniqc([H1,H2|T], Count, Acc) ->
    uniqc([H2|T], 1, [{H1, Count}|Acc]).

uniqc_test() ->
    [{a, 2}, {b, 5}] = uniqc([a, a, b, b, b, b, b]),
    [] = uniqc([]),
    [{c, 1}] = uniqc([c]).

unique(Xs) ->
    [X || {X, _} <- uniqc(Xs)].

keygroup(Index, List) ->
    keygroup(Index, List, []).

keygroup(_, [], Groups) ->
    lists:reverse(Groups);
keygroup(Index, [H|T], Groups) ->
    Key = element(Index, H),
    {G, Rest} = lists:splitwith(fun (Elem) -> element(Index, Elem) == Key end, T),
    keygroup(Index, Rest, [{Key, [H|G]}|Groups]).

keygroup_test() ->
    [{a, [{a, 1}, {a, 2}]},
     {b, [{b, 2}, {b, 3}]}] = keygroup(1, [{a, 1}, {a, 2}, {b, 2}, {b, 3}]),
    [] = keygroup(1, []).

sort_and_keygroup(Index, List) ->
    keygroup(Index, lists:keysort(Index, List)).

%% Turn [[1, 2, 3], [4, 5, 6], [7, 8, 9]] info
%% [[1, 4, 7], [2, 5, 8], [3, 6, 9]]
rotate(List) ->
    rotate(List, [], [], []).

rotate([], [], [], Acc) ->
    lists:reverse(Acc);
rotate([], Heads, Tails, Acc) ->
    rotate(lists:reverse(Tails), [], [], [lists:reverse(Heads)|Acc]);
rotate([[H|T]|Rest], Heads, Tails, Acc) ->
    rotate(Rest, [H|Heads], [T|Tails], Acc);
rotate(_, [], [], Acc) ->
    lists:reverse(Acc).

rotate_test() ->
    [[1, 4, 7], [2, 5, 8], [3, 6, 9]] =
        rotate([[1, 2, 3], [4, 5, 6], [7, 8, 9]]),
    [] = rotate([]).

rewrite(Fun, Term) ->
    case Fun(Term) of
        continue ->
            do_rewrite(Fun, Term);
        {stop, NewTerm} ->
            NewTerm
    end.

do_rewrite(Fun, [H|T]) ->
    [rewrite(Fun, H) | rewrite(Fun, T)];
do_rewrite(_Fun, []) ->
    [];
do_rewrite(Fun, Tuple) when is_tuple(Tuple) ->
    L = [rewrite(Fun, E) || E <- tuple_to_list(Tuple)],
    list_to_tuple(L);
do_rewrite(_Fun, Term) ->
    Term.

rewrite_correctly_callbacks_on_tuples_test() ->
    executing_on_new_process(
      fun () ->
              {a, b, c} =
                  rewrite(
                    fun (Term) ->
                            self() ! {term, Term},
                            continue
                    end, {a, b, c}),
              Terms =
                  letrec(
                    [[]],
                    fun (Rec, Acc) ->
                            receive
                                X ->
                                    {term, T} = X,
                                    Rec(Rec, [T | Acc])
                            after 0 ->
                                    lists:reverse(Acc)
                            end
                    end),
              [{a, b, c}, a, b, c] = Terms
      end).

rewrite_value(Old, New, Struct) ->
    rewrite(
      fun (Term) ->
              case Term =:= Old of
                  true ->
                      {stop, New};
                  false ->
                      continue
              end
      end,
      Struct).

rewrite_key_value_tuple(Key, NewValue, Struct) ->
    rewrite(
      fun (Term) ->
              case Term of
                  {Key, _} ->
                      {stop, {Key, NewValue}};
                  _ ->
                      continue
              end
      end,
      Struct).

rewrite_tuples(Fun, Struct) ->
    rewrite(
      fun (Term) ->
              case is_tuple(Term) of
                  true ->
                      case Fun(Term) of
                          {continue, NewTerm} ->
                              NewTerm1 =
                                  list_to_tuple(
                                    rewrite_tuples(Fun, tuple_to_list(NewTerm))),
                              {stop, NewTerm1};
                          {stop, NewTerm} ->
                              {stop, NewTerm}
                      end;
                  false ->
                      continue
              end
      end,
      Struct).

rewrite_value_test() ->
    x = rewrite_value(a, b, x),
    b = rewrite_value(a, b, a),
    b = rewrite_value(a, b, b),

    [x, y, z] = rewrite_value(a, b, [x, y, z]),

    [x, b, c, b] = rewrite_value(a, b, [x, a, c, a]),

    {x, y} = rewrite_value(a, b, {x, y}),
    {x, b} = rewrite_value(a, b, {x, a}),

    X = rewrite_value(a, b,
                      [ {"a string", 1, x},
                        {"b string", 4, a, {blah, a, b}}]),
    X = [{"a string", 1, x},
         {"b string", 4, b, {blah, b, b}}],

    % handling of improper list
    [a, [x|c]] = rewrite_value(b, x, [a, [b|c]]),
    [a, [b|x]] = rewrite_value(c, x, [a, [b|c]]).

rewrite_key_value_tuple_test() ->
    x = rewrite_key_value_tuple(a, b, x),
    {a, b} = rewrite_key_value_tuple(a, b, {a, c}),
    {b, x} = rewrite_key_value_tuple(a, b, {b, x}),

    Orig = [ {"a string", x},
             {"b string", 4, {a, x, y}, {a, c}, {a, [b, c]}}],
    X = rewrite_key_value_tuple(a, b, Orig),
    X = [{"a string", x},
         {"b string", 4, {a, x, y}, {a, b}, {a, b}}],

    X1 = rewrite_tuples(fun (T) ->
                                case T of
                                    {"a string", _} ->
                                        {stop, {a_string, xxx}};
                                    {a, _} ->
                                        {stop, {a, xxx}};
                                    _ ->
                                        {continue, T}
                                end
                        end, Orig),

    X1 = [{a_string, xxx}, {"b string", 4, {a, x, y}, {a, xxx}, {a, xxx}}].

sanitize_url(Url) when is_binary(Url) ->
    list_to_binary(sanitize_url(binary_to_list(Url)));
sanitize_url(Url) when is_list(Url) ->
    HostIndex = string:chr(Url, $@),
    case HostIndex of
        0 ->
            Url;
        _ ->
            AfterScheme = string:str(Url, "://"),
            case AfterScheme of
                0 ->
                    "*****" ++ string:substr(Url, HostIndex);
                _ ->
                    string:substr(Url, 1, AfterScheme + 2) ++ "*****" ++
                        string:substr(Url, HostIndex)
            end
    end;
sanitize_url(Url) ->
    Url.

sanitize_url_test() ->
    "blah.com/a/b/c" = sanitize_url("blah.com/a/b/c"),
    "ftp://blah.com" = sanitize_url("ftp://blah.com"),
    "http://*****@blah.com" = sanitize_url("http://user:password@blah.com"),
    "*****@blah.com" = sanitize_url("user:password@blah.com").

ukeymergewith(Fun, N, L1, L2) ->
    ukeymergewith(Fun, N, L1, L2, []).

ukeymergewith(_, _, [], [], Out) ->
    lists:reverse(Out);
ukeymergewith(_, _, L1, [], Out) ->
    lists:reverse(Out, L1);
ukeymergewith(_, _, [], L2, Out) ->
    lists:reverse(Out, L2);
ukeymergewith(Fun, N, L1 = [T1|R1], L2 = [T2|R2], Out) ->
    K1 = element(N, T1),
    K2 = element(N, T2),
    case K1 of
        K2 ->
            ukeymergewith(Fun, N, R1, R2, [Fun(T1, T2) | Out]);
        K when K < K2 ->
            ukeymergewith(Fun, N, R1, L2, [T1|Out]);
        _ ->
            ukeymergewith(Fun, N, L1, R2, [T2|Out])
    end.

ukeymergewith_test() ->
    Fun = fun ({K, A}, {_, B}) ->
                  {K, A + B}
          end,
    [{a, 3}] = ukeymergewith(Fun, 1, [{a, 1}], [{a, 2}]),
    [{a, 3}, {b, 1}] = ukeymergewith(Fun, 1, [{a, 1}], [{a, 2}, {b, 1}]),
    [{a, 1}, {b, 3}] = ukeymergewith(Fun, 1, [{b, 1}], [{a, 1}, {b, 2}]).


%% Given two sorted lists, return a 3-tuple containing the elements
%% that appear only in the first list, only in the second list, or are
%% common to both lists, respectively.
comm([H1|T1] = L1, [H2|T2] = L2) ->
    if H1 == H2 ->
            {R1, R2, R3} = comm(T1, T2),
            {R1, R2, [H1|R3]};
       H1 < H2 ->
            {R1, R2, R3} = comm(T1, L2),
            {[H1|R1], R2, R3};
       true ->
            {R1, R2, R3} = comm(L1, T2),
            {R1, [H2|R2], R3}
    end;
comm(L1, L2) when L1 == []; L2 == [] ->
    {L1, L2, []}.


comm_test() ->
    {[1], [2], [3]} = comm([1,3], [2,3]),
    {[1,2,3], [], []} = comm([1,2,3], []),
    {[], [], []} = comm([], []).



start_singleton(Module, Name, Args, Opts) ->
    case Module:start_link({global, Name}, Name, Args, Opts) of
        {error, {already_started, Pid}} ->
            ?log_debug("start_singleton(~p, ~p, ~p, ~p):"
                       " monitoring ~p from ~p",
                       [Module, Name, Args, Opts, Pid, node()]),
            {ok, spawn_link(fun () ->
                                    misc:wait_for_process(Pid, infinity),
                                    ?log_info("~p saw ~p exit (was pid ~p).",
                                              [self(), Name, Pid])
                            end)};
        {ok, Pid} = X ->
            ?log_debug("start_singleton(~p, ~p, ~p, ~p):"
                       " started as ~p on ~p~n",
                       [Module, Name, Args, Opts, Pid, node()]),
            X;
        X -> X
    end.


%% Verify that a given global name belongs to the local pid, exiting
%% if it doesn't.
-spec verify_name(atom()) ->
                         ok | no_return().
verify_name(Name) ->
    case global:whereis_name(Name) of
        Pid when Pid == self() ->
            ok;
        Pid ->
            ?log_error("~p is registered to ~p. Killing ~p.",
                       [Name, Pid, self()]),
            exit(kill)
    end.


key_update_rec(Key, List, Fun, Acc) ->
    case List of
        [{Key, OldValue} | Rest] ->
            %% once we found our key, compute new value and don't recurse anymore
            %% just append rest of list to reversed accumulator
            lists:reverse([{Key, Fun(OldValue)} | Acc],
                          Rest);
        [] ->
            %% if we reach here, then we didn't found our tuple
            false;
        [X | XX] ->
            %% anything that's not our pair is just kept intact
            key_update_rec(Key, XX, Fun, [X | Acc])
    end.

%% replace value of given Key with result of applying Fun on it in
%% given proplist. Preserves order of keys. Assumes Key occurs only
%% once.
key_update(Key, PList, Fun) ->
    key_update_rec(Key, PList, Fun, []).

%% replace values from OldPList with values from NewPList
update_proplist(OldPList, NewPList) ->
    NewPList ++
        lists:filter(fun ({K, _}) ->
                             case lists:keyfind(K, 1, NewPList) of
                                 false -> true;
                                 _ -> false
                             end
                     end, OldPList).

update_proplist_test() ->
    [{a, 1}, {b, 2}, {c,3}] =:= update_proplist([{a,2}, {c,3}],
                                                [{a,1}, {b,2}]).

%% get proplist value or fail
expect_prop_value(K, List) ->
    Ref = make_ref(),
    try
        case proplists:get_value(K, List, Ref) of
            RV when RV =/= Ref -> RV
        end
    catch
        error:X -> erlang:error(X, [K, List])
    end.

%% true iff given path is absolute
is_absolute_path(Path) ->
    Normalized = filename:join([Path]),
    filename:absname(Normalized) =:= Normalized.

%% @doc Truncate a timestamp to the nearest multiple of N seconds.
trunc_ts(TS, N) ->
    TS - (TS rem (N*1000)).

%% alternative of file:read_file/1 that reads file until EOF is
%% reached instead of relying on file length. See
%% http://groups.google.com/group/erlang-programming/browse_thread/thread/fd1ec67ff690d8eb
%% for more information. This piece of code was borrowed from above mentioned URL.
raw_read_file(Path) ->
    case file:open(Path, [read, binary]) of
        {ok, File} -> raw_read_loop(File, []);
        Crap -> Crap
    end.
raw_read_loop(File, Acc) ->
    case file:read(File, 16384) of
        {ok, Bytes} ->
            raw_read_loop(File, [Acc | Bytes]);
        eof ->
            file:close(File),
            {ok, iolist_to_binary(Acc)};
        {error, Reason} ->
            file:close(File),
            erlang:error(Reason)
    end.

assoc_multicall_results_rec([], _ResL, _BadNodes, SuccessAcc, ErrorAcc) ->
    {SuccessAcc, ErrorAcc};
assoc_multicall_results_rec([N | Nodes], Results, BadNodes,
                            SuccessAcc, ErrorAcc) ->
    case lists:member(N, BadNodes) of
        true ->
            assoc_multicall_results_rec(Nodes, Results, BadNodes, SuccessAcc, ErrorAcc);
        _ ->
            [Res | ResRest] = Results,

            case Res of
                {badrpc, Reason} ->
                    NewErrAcc = [{N, Reason} | ErrorAcc],
                    assoc_multicall_results_rec(Nodes, ResRest, BadNodes,
                                                SuccessAcc, NewErrAcc);
                _ ->
                    NewOkAcc = [{N, Res} | SuccessAcc],
                    assoc_multicall_results_rec(Nodes, ResRest, BadNodes,
                                                NewOkAcc, ErrorAcc)
            end
    end.

%% Returns a pair of proplists and list of nodes. First element is a
%% mapping from Nodes to return values for nodes that
%% succeeded. Second one is a mapping from Nodes to error reason for
%% failed nodes. And third tuple element is BadNodes argument unchanged.
-spec assoc_multicall_results([node()], [any() | {badrpc, any()}], [node()]) ->
                                    {OkNodeResults::[{node(), any()}],
                                     BadRPCNodeResults::[{node(), any()}],
                                     BadNodes::[node()]}.
assoc_multicall_results(Nodes, ResL, BadNodes) ->
    {OkNodeResults, BadRPCNodeResults} = assoc_multicall_results_rec(Nodes, ResL, BadNodes, [], []),
    {OkNodeResults, BadRPCNodeResults, BadNodes}.

%% Performs rpc:multicall and massages results into "normal results",
%% {badrpc, ...} results and timeouts/disconnects. Returns triple
%% produced by assoc_multicall_results/3 above.
rpc_multicall_with_plist_result(Nodes, M, F, A, Timeout) ->
    {ResL, BadNodes} = rpc:multicall(Nodes, M, F, A, Timeout),
    assoc_multicall_results(Nodes, ResL, BadNodes).

rpc_multicall_with_plist_result(Nodes, M, F, A) ->
    rpc_multicall_with_plist_result(Nodes, M, F, A, infinity).

-spec realpath(string(), string()) -> {ok, string()} | {error, atom(), string(), any()}.
realpath(Path, BaseDir) ->
    case erlang:system_info(system_architecture) of
        "win32" ->
            {ok, filename:absname(Path, BaseDir)};
        _ -> case realpath_full(Path, BaseDir, 32) of
                 {ok, X, _} -> {ok, X};
                 X -> X
             end
    end.

-spec realpath_full(string(), string(), integer()) -> {ok, string(), integer()} | {error, atom(), string(), any()}.
realpath_full(Path, BaseDir, SymlinksLimit) ->
    NormalizedPath = filename:join([Path]),
    Tokens = string:tokens(NormalizedPath, "/"),
    case Path of
        [$/ | _] ->
            %% if we're absolute path then start with root
            realpath_rec_check("/", Tokens, SymlinksLimit);
        _ ->
            %% otherwise start walking from BaseDir
            realpath_rec_info(#file_info{type = other}, BaseDir, Tokens, SymlinksLimit)
    end.

%% this is called to check type of Current pathname and expand it if it's symlink
-spec realpath_rec_check(string(), [string()], integer()) -> {ok, string(), integer()} |
                                                             {error, atom(), string(), any()}.
realpath_rec_check(Current, Tokens, SymlinksLimit) ->
    case file:read_link_info(Current) of
        {ok, Info} ->
            realpath_rec_info(Info, Current, Tokens, SymlinksLimit);
        Crap -> {error, read_file_info, Current, Crap}
    end.

%% this implements 'meat' of path name lookup
-spec realpath_rec_info(tuple(), string(), [string()], integer()) -> {ok, string(), integer()} |
                                                                     {error, atom(), string(), any()}.
%% this case handles Current being symlink. Symlink is recursively
%% expanded and we continue path name walking from expanded place
realpath_rec_info(Info, Current, Tokens, SymlinksLimit) when Info#file_info.type =:= symlink ->
    case file:read_link(Current) of
        {error, _} = Crap -> {error, read_link, Current, Crap};
        {ok, LinkDestination} ->
            case SymlinksLimit of
                0 -> {error, symlinks_limit_reached, Current, undefined};
                _ ->
                    case realpath_full(LinkDestination, filename:dirname(Current), SymlinksLimit-1) of
                        {ok, Expanded, NewSymlinksLimit} ->
                            realpath_rec_check(Expanded, Tokens, NewSymlinksLimit);
                        Error -> Error
                    end
            end
    end;
%% this case handles end of path name walking
realpath_rec_info(_, Current, [], SymlinksLimit) ->
    {ok, Current, SymlinksLimit};
%% this case just removes single dot
realpath_rec_info(Info, Current, ["." | Tokens], SymlinksLimit) ->
    realpath_rec_info(Info, Current, Tokens, SymlinksLimit);
%% this case implements ".."
realpath_rec_info(_Info, Current, [".." | Tokens], SymlinksLimit) ->
    realpath_rec_check(filename:dirname(Current), Tokens, SymlinksLimit);
%% this handles most common case of walking single level of file tree
realpath_rec_info(_Info, Current, [FirstToken | Tokens], SymlinksLimit) ->
    NewCurrent = filename:absname(FirstToken, Current),
    realpath_rec_check(NewCurrent, Tokens, SymlinksLimit).

-spec split_binary_at_char(binary(), char()) -> binary() | {binary(), binary()}.
split_binary_at_char(Binary, Chr) ->
    case binary:split(Binary, <<Chr:8>>) of
        [_] -> Binary;
        [Part1, Part2] -> {Part1, Part2}
    end.

is_binary_ends_with(Binary, Suffix) ->
    binary:longest_common_suffix([Binary, Suffix]) =:= size(Suffix).

absname(Name) ->
    PathType = filename:pathtype(Name),
    case PathType of
        absolute ->
            filename:absname(Name, "/");
        _ ->
            filename:absname(Name)
    end.

start_event_link(SubscriptionBody) ->
    {ok,
     spawn_link(fun () ->
                        SubscriptionBody(),
                        receive
                            _ -> ok
                        end
                end)}.

%% Writes to file atomically using write_file + atomic_rename
atomic_write_file(Path, BodyOrBytes)
  when is_function(BodyOrBytes);
       is_binary(BodyOrBytes);
       is_list(BodyOrBytes) ->
    DirName = filename:dirname(Path),
    FileName = filename:basename(Path),
    TmpPath = path_config:tempfile(DirName, FileName, ".tmp"),
    try
        case misc:write_file(TmpPath, BodyOrBytes) of
            ok ->
                atomic_rename(TmpPath, Path);
            X ->
                X
        end
    after
        (catch file:delete(TmpPath))
    end.

%% Rename file (more or less) atomically.
%% See https://lwn.net/Articles/351422/ for some details.
%%
%% NB: this does not work on Windows
%% (http://osdir.com/ml/racket.development/2011-01/msg00149.html).
atomic_rename(From, To) ->
    case file:open(From, [raw, binary, read, write]) of
        {ok, IO} ->
            SyncRV =
                try
                    file:sync(IO)
                after
                    ok = file:close(IO)
                end,
            case SyncRV of
                ok ->
                    %% NOTE: linux manpages also mention sync
                    %% on directory, but erlang can't do that
                    %% and that's not portable
                    file:rename(From, To);
                _ ->
                    SyncRV
            end;
        Err ->
            Err
    end.

%% Get an item from from a dict, if it doesnt exist return default
-spec dict_get(term(), dict(), term()) -> term().
dict_get(Key, Dict, Default) ->
    case dict:find(Key, Dict) of
        {ok, Value} ->
            Value;
        error ->
            Default
    end.

%% like dict:update/4 but calls the function on initial value instead of just
%% storing it in the dict
dict_update(Key, Fun, Initial, Dict) ->
    try
        dict:update(Key, Fun, Dict)
    catch
        %% key not found
        error:badarg ->
            dict:store(Key, Fun(Initial), Dict)
    end.

%% Parse version of the form 1.7.0r_252_g1e1c2c0 or 1.7.0r-252-g1e1c2c0 into a
%% list {[1,7,0],candidate,252}.  1.8.0 introduces a license type suffix,
%% like: 1.8.0r-25-g1e1c2c0-enterprise.  Note that we should never
%% see something like 1.7.0-enterprise, as older nodes won't carry
%% the license type information.
-spec parse_version(string()) -> version().
parse_version(VersionStr) ->
    Parts = string:tokens(VersionStr, "_-"),
    case Parts of
        [BaseVersionStr] ->
            {BaseVersion, Type} = parse_base_version(BaseVersionStr),
            {BaseVersion, Type, 0};
        [BaseVersionStr, OffsetStr | _Rest] ->
            {BaseVersion, Type} = parse_base_version(BaseVersionStr),
            {BaseVersion, Type, list_to_integer(OffsetStr)}
    end.

-define(VERSION_REGEXP,
        "^((?:[0-9]+\.)*[0-9]+).*?(r)?$"). % unbreak font-lock "

parse_base_version(BaseVersionStr) ->
    case re:run(BaseVersionStr, ?VERSION_REGEXP,
                [{capture, all_but_first, list}]) of
        {match, [NumericVersion, "r"]} ->
            Type = candidate;
        {match, [NumericVersion]} ->
            Type = release
    end,

    {lists:map(fun list_to_integer/1,
               string:tokens(NumericVersion, ".")), Type}.

this_node_rest_port() ->
    node_rest_port(node()).

node_rest_port(Node) ->
    node_rest_port(ns_config:latest(), Node).

node_rest_port(Config, Node) ->
    case ns_config:search_node_prop(Node, Config, rest, port_meta, local) of
        local ->
            ns_config:search_node_prop(Node, Config, rest, port, 8091);
        global ->
            ns_config:search_prop(Config, rest, port, 8091)
    end.

-ifdef(EUNIT).
parse_version_test() ->
    ?assertEqual({[1,7,0],release,252},
                 parse_version("1.7.0_252_g1e1c2c0")),
    ?assertEqual({[1,7,0],release,252},
                 parse_version("1.7.0-252-g1e1c2c0")),
    ?assertEqual({[1,7,0],candidate,252},
                 parse_version("1.7.0r_252_g1e1c2c0")),
    ?assertEqual({[1,7,0],candidate,252},
                 parse_version("1.7.0r-252-g1e1c2c0")),
    ?assertEqual({[1,7,0],release,0},
                 parse_version("1.7.0")),
    ?assertEqual({[1,7,0],candidate,0},
                 parse_version("1.7.0r")),
    ?assertEqual(true,
                 parse_version("1.7.0") >
                     parse_version("1.7.0r_252_g1e1c2c0")),
    ?assertEqual(true,
                 parse_version("1.7.0") >
                     parse_version("1.7.0r")),
    ?assertEqual(true,
                 parse_version("1.7.1r") >
                     parse_version("1.7.0")),
    ?assertEqual(true,
                 parse_version("1.7.1_252_g1e1c2c0") >
                     parse_version("1.7.1_251_g1e1c2c1")),
    ?assertEqual({[1,8,0],release,25},
                 parse_version("1.8.0_25_g1e1c2c0-enterprise")),
    ?assertEqual({[1,8,0],release,25},
                 parse_version("1.8.0-25-g1e1c2c0-enterprise")),
    ?assertEqual({[2,0,0],candidate,702},
                 parse_version("2.0.0dp4r-702")),
    ?assertEqual({[2,0,0],candidate,702},
                 parse_version("2.0.0dp4r-702-g1e1c2c0")),
    ?assertEqual({[2,0,0],candidate,702},
                 parse_version("2.0.0dp4r-702-g1e1c2c0-enterprise")),
    ?assertEqual({[2,0,0],release,702},
                 parse_version("2.0.0dp4-702")),
    ?assertEqual({[2,0,0],release,702},
                 parse_version("2.0.0dp4-702-g1e1c2c0")),
    ?assertEqual({[2,0,0],release,702},
                 parse_version("2.0.0dp4-702-g1e1c2c0-enterprise")),
    ok.

ceiling_test() ->
    ?assertEqual(4, ceiling(4)),
    ?assertEqual(4, ceiling(4.0)),
    ?assertEqual(4, ceiling(3.99)),
    ?assertEqual(4, ceiling(3.01)),
    ?assertEqual(-4, ceiling(-4)),
    ?assertEqual(-4, ceiling(-4.0)),
    ?assertEqual(-4, ceiling(-4.99)),
    ?assertEqual(-4, ceiling(-4.01)),
    ok.

-endif.

compute_map_diff(undefined, OldMap) ->
    compute_map_diff([], OldMap);
compute_map_diff(NewMap, undefined) ->
    compute_map_diff(NewMap, []);
compute_map_diff([], []) ->
    [];
compute_map_diff(NewMap, []) when NewMap =/= [] ->
    compute_map_diff(NewMap, [[] || _ <- NewMap]);
compute_map_diff([], OldMap) when OldMap =/= [] ->
    compute_map_diff([[] || _ <- OldMap], OldMap);
compute_map_diff(NewMap, OldMap) ->
    VBucketsCount = erlang:length(NewMap),
    [{I, ChainOld, ChainNew} ||
        {I, ChainOld, ChainNew} <-
            lists:zip3(lists:seq(0, VBucketsCount-1), OldMap, NewMap),
        ChainOld =/= ChainNew].

%% execute body in newly spawned process. Function returns when Body
%% returns and with it's return value. If body produced any exception
%% it will be rethrown. Care is taken to propagate exits of 'parent'
%% process to this worker process.
executing_on_new_process(Body) ->
    async:with(Body, fun async:wait/1).

%% returns if Reason is EXIT caused by undefined function/module
is_undef_exit(M, F, A, {undef, [{M, F, A, []} | _]}) -> true; % R15, R16
is_undef_exit(M, F, A, {undef, [{M, F, A} | _]}) -> true; % R14
is_undef_exit(_M, _F, _A, _Reason) -> false.

is_timeout_exit({'EXIT', timeout}) -> true;
is_timeout_exit({'EXIT', {timeout, _}}) -> true;
is_timeout_exit(_) -> false.

-spec sync_shutdown_many_i_am_trapping_exits(Pids :: [pid()]) -> ok.
sync_shutdown_many_i_am_trapping_exits(Pids) ->
    {trap_exit, true} = erlang:process_info(self(), trap_exit),
    [(catch erlang:exit(Pid, shutdown)) || Pid <- Pids],
    BadShutdowns = [{P, RV} || P <- Pids,
                               (RV = inner_wait_shutdown(P)) =/= shutdown],
    case BadShutdowns of
        [] -> ok;
        _ ->
            ?log_error("Shutdown of the following failed: ~p", [BadShutdowns])
    end,
    [] = BadShutdowns,
    ok.

%% NOTE: this is internal helper, despite everything being exported
%% from here
-spec inner_wait_shutdown(Pid :: pid()) -> term().
inner_wait_shutdown(Pid) ->
    MRef = erlang:monitor(process, Pid),
    MRefReason = receive
                     {'DOWN', MRef, _, _, MRefReason0} ->
                         MRefReason0
                 end,
    receive
        {'EXIT', Pid, Reason} ->
            Reason
    after 5000 ->
            ?log_error("Expected exit signal from ~p but could not get it in 5 seconds. This is a bug, but process we're waiting for is dead (~p), so trying to ignore...", [Pid, MRefReason]),
            ?log_debug("Here's messages:~n~p", [erlang:process_info(self(), messages)]),
            MRefReason
    end.

%% @doc works like try/after but when try has raised exception, any
%% exception from AfterBody is logged and ignored. I.e. when we face
%% exceptions from both try-block and after-block, exception from
%% after-block is logged and ignored and exception from try-block is
%% rethrown. Use this when exception from TryBody is more important
%% than exception from AfterBody.
try_with_maybe_ignorant_after(TryBody, AfterBody) ->
    RV =
        try TryBody()
        catch T:E ->
                Stacktrace = erlang:get_stacktrace(),
                try AfterBody()
                catch T2:E2 ->
                        ?log_error("Eating exception from ignorant after-block:~n~p", [{T2, E2, erlang:get_stacktrace()}])
                end,
                erlang:raise(T, E, Stacktrace)
        end,
    AfterBody(),
    RV.

letrec(Args, F) ->
    erlang:apply(F, [F | Args]).

-spec is_good_address(string()) -> ok | {cannot_resolve, inet:posix()}
                                       | {cannot_listen, inet:posix()}
                                       | {address_not_allowed, string()}.
is_good_address(Address) ->
    case string:tokens(Address, ".") of
        [_] ->
            {address_not_allowed, "short names are not allowed. Couchbase Server requires at least one dot in a name"};
        _ ->
            is_good_address_when_allowed(Address)
    end.

is_good_address_when_allowed(Address) ->
    case inet:getaddr(Address, inet) of
        {error, Errno} ->
            {cannot_resolve, Errno};
        {ok, IpAddr} ->
            case gen_udp:open(0, [inet, {ip, IpAddr}]) of
                {error, Errno} ->
                    {cannot_listen, Errno};
                {ok, Socket} ->
                    gen_udp:close(Socket),
                    ok
            end
    end.

delaying_crash(DelayBy, Body) ->
    try
        Body()
    catch T:E ->
            ST = erlang:get_stacktrace(),
            ?log_debug("Delaying crash ~p:~p by ~pms~nStacktrace: ~p", [T, E, DelayBy, ST]),
            timer:sleep(DelayBy),
            erlang:raise(T, E, ST)
    end.

%% Like erlang:memory but returns 'notsup' if it's impossible to get this
%% information.
memory() ->
    try
        erlang:memory()
    catch
        error:notsup ->
            notsup
    end.

ensure_writable_dir(Path) ->
    filelib:ensure_dir(Path),
    case filelib:is_dir(Path) of
        true ->
            TouchPath = filename:join(Path, ".touch"),
            case misc:write_file(TouchPath, <<"">>) of
                ok ->
                    file:delete(TouchPath),
                    ok;
                _ -> error
            end;
        _ ->
            case file:make_dir(Path) of
                ok -> ok;
                _ ->
                    error
            end
    end.

ensure_writable_dirs([]) ->
    ok;
ensure_writable_dirs([Path | Rest]) ->
    case ensure_writable_dir(Path) of
        ok ->
            ensure_writable_dirs(Rest);
        X -> X
    end.

%% Like lists:split but does not fail if N > length(List).
safe_split(N, List) ->
    do_safe_split(N, List, []).

do_safe_split(_, [], Acc) ->
    {lists:reverse(Acc), []};
do_safe_split(0, List, Acc) ->
    {lists:reverse(Acc), List};
do_safe_split(N, [H|T], Acc) ->
    do_safe_split(N - 1, T, [H|Acc]).

-spec run_external_tool(string(), [string()]) -> {non_neg_integer(), binary()}.
run_external_tool(Path, Args) ->
    run_external_tool(Path, Args, []).

-spec run_external_tool(string(), [string()], [{string(), string()}]) -> {non_neg_integer(), binary()}.
run_external_tool(Path, Args, Env) ->
    executing_on_new_process(
      fun () ->
              Port = erlang:open_port({spawn_executable, Path},
                                      [stderr_to_stdout, binary,
                                       stream, exit_status, hide,
                                       {args, Args},
                                       {env, Env}]),
              collect_external_tool_output(Port, [])
      end).

collect_external_tool_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_external_tool_output(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))};
        Msg ->
            ?log_error("Got unexpected message"),
            exit({unexpected_message, Msg})
    end.

min_by(Less, Items) ->
    lists:foldl(
      fun (Elem, Acc) ->
              case Less(Elem, Acc) of
                  true ->
                      Elem;
                  false ->
                      Acc
              end
      end, hd(Items), tl(Items)).

inspect_term(Value) ->
    binary_to_list(iolist_to_binary(io_lib:format("~p", [Value]))).

with_file(Path, Mode, Body) ->
    case file:open(Path, Mode) of
        {ok, F} ->
            try
                Body(F)
            after
                (catch file:close(F))
            end;
        Error ->
            Error
    end.

write_file(Path, Bytes) when is_binary(Bytes); is_list(Bytes) ->
    misc:write_file(Path,
                    fun (F) ->
                            file:write(F, Bytes)
                    end);
write_file(Path, Body) when is_function(Body) ->
    with_file(Path, [raw, binary, write], Body).

halt(Status) ->
    try
        erlang:halt(Status, [{flush, false}])
    catch
        error:undef ->
            erlang:halt(Status)
    end.

%% Ensure that directory exists. Analogous to running mkdir -p in shell.
mkdir_p(Path) ->
    case filelib:ensure_dir(Path) of
        ok ->
            case file:make_dir(Path) of
                {error, eexist} ->
                    case file:read_file_info(Path) of
                        {ok, Info} ->
                            case Info#file_info.type of
                                directory ->
                                    ok;
                                _ ->
                                    {error, eexist}
                            end;
                        Error ->
                            Error
                    end;
                %% either ok or other error
                Other ->
                    Other
            end;
        Error ->
            Error
    end.

create_marker(Path, Data) when is_list(Data) ->
    ok = misc:write_file(Path, list_to_binary(Data)).

create_marker(Path) ->
    ok = misc:write_file(Path, <<"">>).

remove_marker(Path) ->
    ok = file:delete(Path).

marker_exists(Path) ->
    case file:read_file_info(Path) of
        {ok, _} ->
            true;
        {error, enoent} ->
            false;
        Other ->
            ?log_error("Unexpected error when reading marker ~p: ~p", [Path, Other]),
            exit({failed_to_read_marker, Path, Other})
    end.

read_marker(Path) ->
    case file:read_file(Path) of
        {ok, BinaryContents} ->
            {ok, binary_to_list(BinaryContents)};
        {error, enoent} ->
            false;
        Other ->
            ?log_error("Unexpected error when reading marker ~p: ~p", [Path, Other]),
            exit({failed_to_read_marker, Path, Other})
    end.

is_free_nodename(ShortName) ->
    {ok, Names} = erl_epmd:names({127,0,0,1}),
    not lists:keymember(ShortName, 1, Names).

wait_for_nodename(ShortName) ->
    wait_for_nodename(ShortName, 5).

wait_for_nodename(ShortName, Attempts) ->
    case is_free_nodename(ShortName) of
        true ->
            ok;
        false ->
            case Attempts of
                0 ->
                    {error, duplicate_name};
                _ ->
                    ?log_info("Short name ~s is still occupied. "
                              "Will try again after a bit", [ShortName]),
                    timer:sleep(500),
                    wait_for_nodename(ShortName, Attempts - 1)
            end
    end.

is_prefix(KeyPattern, K) ->
    KPL = size(KeyPattern),
    case K of
        <<KeyPattern:KPL/binary, _/binary>> ->
            true;
        _ ->
            false
    end.

eval(Str,Binding) ->
    {ok,Ts,_} = erl_scan:string(Str),
    Ts1 = case lists:reverse(Ts) of
              [{dot,_}|_] -> Ts;
              TsR -> lists:reverse([{dot,1} | TsR])
          end,
    {ok,Expr} = erl_parse:parse_exprs(Ts1),
    erl_eval:exprs(Expr, Binding).

get_ancestors() ->
    erlang:get('$ancestors').

multi_call(Nodes, Name, Request, Timeout) ->
    multi_call(Nodes, Name, Request, Timeout, fun (_) -> true end).

%% Behaves like gen_server:multi_call except that instead of just returning a
%% list of "bad nodes" it returns some details about why a call failed.
%%
%% In addition it takes a predicate that can classify an ok reply as an
%% error. Such a reply will be put into the bad replies list.
-spec multi_call(Nodes, Name, Request, Timeout, OkPred) -> Result
  when Nodes   :: [node()],
       Name    :: atom(),
       Request :: any(),
       Timeout :: infinity | non_neg_integer(),
       Result  :: {Good, Bad},
       Good    :: [{node(), any()}],
       Bad     :: [{node(), any()}],

       OkPred   :: fun((any()) -> OkPredRV),
       OkPredRV :: boolean() | {false, ErrorTerm :: term()}.
multi_call(Nodes, Name, Request, Timeout, OkPred) ->
    Ref = erlang:make_ref(),
    Parent = self(),
    try
        parallel_map(
          fun (N) ->
                  RV = try gen_server:call({Name, N}, Request, infinity) of
                           Res ->
                               case OkPred(Res) of
                                   true ->
                                       {ok, Res};
                                   false ->
                                       {error, Res};
                                   {false, ErrorTerm} ->
                                       {error, ErrorTerm}
                               end
                       catch T:E ->
                               {error, {T, E}}
                       end,
                  Parent ! {Ref, {N, RV}}
          end, Nodes, Timeout)
    catch exit:timeout ->
            ok
    end,
    multi_call_collect(ordsets:from_list(Nodes), [], [], [], Ref).

multi_call_collect(Nodes, GotNodes, AccGood, AccBad, Ref) ->
    receive
        {Ref, {N, Result}} ->
            {NewGood, NewBad} =
                case Result of
                    {ok, Good} ->
                        {[{N, Good} | AccGood], AccBad};
                    {error, Bad} ->
                        {AccGood, [{N, Bad} | AccBad]}
                end,

            multi_call_collect(Nodes, [N | GotNodes], NewGood, NewBad, Ref)
    after 0 ->
            TimeoutNodes = ordsets:subtract(Nodes, ordsets:from_list(GotNodes)),
            BadNodes = [{N, timeout} || N <- TimeoutNodes] ++ AccBad,
            {AccGood, BadNodes}
    end.

-ifdef(EUNIT).

multi_call_test_() ->
    {setup, fun multi_call_test_setup/0, fun multi_call_test_teardown/1,
     [fun do_test_multi_call/0]}.

multi_call_test_setup_server() ->
    {ok, Pid} = mock_gen_server:start_link({local, multi_call_server}),
    ok = mock_gen_server:stub_call(Pid, echo,
                                   fun ({echo, V}) ->
                                           V
                                   end),
    ok = mock_gen_server:stub_call(Pid, sleep,
                                   fun ({sleep, Time}) ->
                                           timer:sleep(Time)
                                   end),
    ok = mock_gen_server:stub_call(Pid, eval,
                                   fun ({eval, Fun}) ->
                                           Fun()
                                   end).

multi_call_test_setup() ->
    NodeNames = [a, b, c, d, e],
    {TestNode, Host0} = misc:node_name_host(node()),
    Host = list_to_atom(Host0),

    CodePath = code:get_path(),
    Nodes = lists:map(
              fun (N) ->
                      FullName = list_to_atom(atom_to_list(N) ++ "-" ++ TestNode),
                      {ok, Node} = slave:start(Host, FullName),
                      true = rpc:call(Node, code, set_path, [CodePath]),
                      ok = rpc:call(Node, misc, multi_call_test_setup_server, []),
                      Node
              end, NodeNames),
    erlang:put(nodes, Nodes).

multi_call_test_teardown(_) ->
    Nodes = erlang:get(nodes),
    lists:foreach(
      fun (Node) ->
              ok = slave:stop(Node)
      end, Nodes).

multi_call_test_assert_bad_nodes(Bad, Expected) ->
    BadNodes = [N || {N, _} <- Bad],
    ?assertEqual(lists:sort(BadNodes), lists:sort(Expected)).

multi_call_test_assert_results(RVs, Nodes, Result) ->
    lists:foreach(
      fun (N) ->
              RV = proplists:get_value(N, RVs),
              ?assertEqual(RV, Result)
      end, Nodes).

do_test_multi_call() ->
    Nodes = nodes(),
    BadNodes = [bad_node],

    {R1, Bad1} = misc:multi_call(Nodes, multi_call_server, {echo, ok}, 100),

    multi_call_test_assert_results(R1, Nodes, ok),
    multi_call_test_assert_bad_nodes(Bad1, []),

    {R2, Bad2} = misc:multi_call(BadNodes ++ Nodes,
                                 multi_call_server, {echo, ok}, 100),
    multi_call_test_assert_results(R2, Nodes, ok),
    multi_call_test_assert_bad_nodes(Bad2, BadNodes),

    [FirstNode | RestNodes] = Nodes,
    catch gen_server:call({multi_call_server, FirstNode}, {sleep, 100000}, 100),

    {R3, Bad3} = misc:multi_call(Nodes, multi_call_server, {echo, ok}, 100),
    multi_call_test_assert_results(R3, RestNodes, ok),
    ?assertEqual(Bad3, [{FirstNode, timeout}]),

    true = rpc:call(FirstNode, erlang, apply,
                    [fun () ->
                             erlang:exit(whereis(multi_call_server), kill)
                     end, []]),
    {R4, Bad4} = misc:multi_call(Nodes, multi_call_server, {echo, ok}, 100),
    multi_call_test_assert_results(R4, RestNodes, ok),
    ?assertMatch([{FirstNode, {exit, {noproc, _}}}], Bad4).

multi_call_ok_pred_test_() ->
    {setup, fun multi_call_test_setup/0, fun multi_call_test_teardown/1,
     [fun do_test_multi_call_ok_pred/0]}.

do_test_multi_call_ok_pred() ->
    Nodes = nodes(),
    BadNodes = [bad_node],
    AllNodes = BadNodes ++ Nodes,

    {R1, Bad1} = misc:multi_call(AllNodes, multi_call_server, {echo, ok}, 100,
                                 fun (_) -> false end),

    ?assertEqual(R1, []),
    multi_call_test_assert_bad_nodes(Bad1, AllNodes),

    {R2, Bad2} = misc:multi_call(AllNodes, multi_call_server, {echo, ok}, 100,
                                 fun (_) -> {false, some_error} end),
    ?assertEqual(R2, []),
    multi_call_test_assert_bad_nodes(Bad2, AllNodes),
    multi_call_test_assert_results(Bad2, Nodes, some_error),

    {OkNodes, ErrorNodes} = lists:split(length(Nodes) div 2, misc:shuffle(Nodes)),
    {R3, Bad3} = misc:multi_call(AllNodes, multi_call_server,
                                 {eval, fun () ->
                                                case lists:member(node(), OkNodes) of
                                                    true ->
                                                        ok;
                                                    false ->
                                                        error
                                                end
                                        end},
                                 100,
                                 fun (RV) ->
                                         RV =:= ok
                                 end),

    multi_call_test_assert_results(R3, OkNodes, ok),
    multi_call_test_assert_bad_nodes(Bad3, BadNodes ++ ErrorNodes),
    multi_call_test_assert_results(Bad3, ErrorNodes, error).

-endif.

intersperse([], _) ->
    [];
intersperse([_] = List, _) ->
    List;
intersperse([X | Rest], Sep) ->
    [X, Sep | intersperse(Rest, Sep)].

-ifdef(EUNIT).
intersperse_test() ->
    ?assertEqual([], intersperse([], x)),
    ?assertEqual([a], intersperse([a], x)),
    ?assertEqual([a,x,b,x,c], intersperse([a,b,c], x)).
-endif.

hexify(Binary) ->
    << <<(hexify_digit(High)), (hexify_digit(Low))>>
       || <<High:4, Low:4>> <= Binary >>.

hexify_digit(0) -> $0;
hexify_digit(1) -> $1;
hexify_digit(2) -> $2;
hexify_digit(3) -> $3;
hexify_digit(4) -> $4;
hexify_digit(5) -> $5;
hexify_digit(6) -> $6;
hexify_digit(7) -> $7;
hexify_digit(8) -> $8;
hexify_digit(9) -> $9;
hexify_digit(10) -> $a;
hexify_digit(11) -> $b;
hexify_digit(12) -> $c;
hexify_digit(13) -> $d;
hexify_digit(14) -> $e;
hexify_digit(15) -> $f.

-ifdef(EUNIT).
hexify_test() ->
    lists:foreach(
      fun (_) ->
              R = crypto:rand_bytes(256),
              Hex = hexify(R),

              Etalon0 = string:to_lower(integer_to_list(binary:decode_unsigned(R), 16)),
              Etalon1 =
                  case erlang:byte_size(R) * 2 - length(Etalon0) of
                      0 ->
                          Etalon0;
                      N when N > 0 ->
                          lists:duplicate(N, $0) ++ Etalon0
                  end,
              Etalon = list_to_binary(Etalon1),

              ?assertEqual(Hex, Etalon)
      end, lists:seq(1, 100)).
-endif.

iolist_is_empty(<<>>) ->
    true;
iolist_is_empty([]) ->
    true;
iolist_is_empty([H|T]) ->
    iolist_is_empty(H) andalso iolist_is_empty(T);
iolist_is_empty(_) ->
    false.

-ifdef(EUNIT).
iolist_is_empty_test() ->
    ?assertEqual(iolist_is_empty(""), true),
    ?assertEqual(iolist_is_empty(<<>>), true),
    ?assertEqual(iolist_is_empty([[[<<>>]]]), true),
    ?assertEqual(iolist_is_empty([[]|<<>>]), true),
    ?assertEqual(iolist_is_empty([<<>>|[]]), true),
    ?assertEqual(iolist_is_empty([[[]], <<"test">>]), false),
    ?assertEqual(iolist_is_empty([[<<>>]|"test"]), false).
-endif.

ejson_encode_pretty(Json) ->
    iolist_to_binary(
      pipes:run(sjson:stream_json(Json),
                sjson:encode_json([{compact, false},
                                   {strict, false}]),
                pipes:collect())).

upermutations(Xs) ->
    do_upermutations(lists:sort(Xs)).

do_upermutations([]) ->
    [[]];
do_upermutations(Xs) ->
    [[X|Ys] || X <- unique(Xs), Ys <- do_upermutations(Xs -- [X])].

prop_upermutations() ->
    ?FORALL(Xs, resize(10, list(int(0,5))),
            begin
                Perms = upermutations(Xs),

                NoDups = (lists:usort(Perms) =:= Perms),

                XsSorted = lists:sort(Xs),
                ProperPerms =
                    lists:all(
                      fun (P) ->
                              lists:sort(P) =:= XsSorted
                      end, Perms),

                N = length(Xs),
                Counts = [C || {_, C} <- uniqc(XsSorted)],
                ExpectedSize =
                    fact(N) div lists:foldl(
                                  fun (X, Y) -> X * Y end,
                                  1,
                                  lists:map(fun fact/1, Counts)),
                ProperSize = (ExpectedSize =:= length(Perms)),

                NoDups andalso ProperPerms andalso ProperSize
            end).

fact(0) ->
    1;
fact(N) ->
    N * fact(N-1).
