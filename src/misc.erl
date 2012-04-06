% Copyright (c) 2009, NorthScale, Inc.
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
-include_lib("eunit/include/eunit.hrl").

-define(FNV_OFFSET_BASIS, 2166136261).
-define(FNV_PRIME,        16777619).

-compile(export_all).

-define(prof(Label), true).
-define(forp(Label), true).
-define(balance_prof, true).

shuffle(List) when is_list(List) ->
    [N || {_R, N} <- lists:keysort(1, [{random:uniform(), X} || X <- List])].

%% applies (catch Fun(X)) for each element of list in parallel. If
%% execution takes longer than given Timeout it'll exit with reason
%% timeout (which is consistent with behavior of gen_XXX:call
%% modules).  Care is taken to not leave any messages in calling
%% process mailbox and to correctly shutdown any worker processes
%% if/when calling process is killed.
-spec parallel_map(fun((any()) -> any()), [any()], non_neg_integer() | infinity) -> [any()].
parallel_map(Fun, List, Timeout) when is_list(List) andalso is_function(Fun) ->
    MainParent = self(),
    Ref = erlang:make_ref(),
    IntermediatePid =
        spawn(fun () ->
                      Parent = self(),
                      erlang:monitor(process, MainParent),
                      {_Pids, RepliesLeft}
                          = lists:foldl(
                              fun (E, {Acc, I}) ->
                                      Pid = spawn_link(
                                              fun () ->
                                                      Parent ! {I, (catch Fun(E))}
                                              end),
                                      {[Pid | Acc], I+1}
                              end, {[], 0}, List),
                      RV = parallel_map_gather_loop(Ref, [], RepliesLeft),
                      MainParent ! {Ref, RV}
              end),
    MRef = erlang:monitor(process, IntermediatePid),
    receive
        {Ref, RV} ->
            receive
                {'DOWN', MRef, _, _, _} -> ok
            end,
            RV;
        {'DOWN', MRef, _, _, Reason} ->
            exit({child_died, Reason})
    after Timeout ->
            IntermediatePid ! {'DOWN', [], [], [], []},
            receive
                {'DOWN', MRef, _, _, _} -> ok
            end,
            receive
                {Ref, _} -> ok
            after 0 -> ok
            end,
            exit(timeout)
    end.

safe_multi_call(Nodes, Name, Request, Timeout) ->
    Ref = erlang:make_ref(),
    Parent = self(),
    try
        parallel_map(fun (N) ->
                             try gen_server:call({Name, N}, Request, infinity) of
                                 Res ->
                                     Parent ! {Ref, {N, Res}}
                             catch _:_ -> ok
                             end,
                             ok
                     end, Nodes, Timeout)
    catch exit:timeout ->
            ok
    end,
    safe_multi_call_collect(lists:sort(Nodes), [], [], Ref).

safe_multi_call_collect(Nodes, GotNodes, Acc, Ref) ->
    receive
        {Ref, {N, _} = Pair} ->
            safe_multi_call_collect(Nodes, [N|GotNodes], [Pair|Acc], Ref)
    after 0 ->
            BadNodes = ordsets:subtract(Nodes, lists:sort(GotNodes)),
            {Acc, BadNodes}
    end.

parallel_map_gather_loop(_Ref, Acc, 0) ->
    [V || {_, V} <- lists:keysort(1, Acc)];
parallel_map_gather_loop(Ref, Acc, RepliesLeft) ->
    receive
        {_I, _Res} = Pair ->
            parallel_map_gather_loop(Ref, [Pair|Acc], RepliesLeft-1);
        {'DOWN', _, _, _, _} ->
            exit(harakiri)
    end.

sys_info_collect_loop(FilePath) ->
    {ok, IO} = file:open(FilePath, [write]),
    sys_info(IO),
    file:close(IO),
    receive
        stop -> ok
    after 5000 -> sys_info_collect_loop(FilePath)
    end.

sys_info(IO) ->
    ok = io:format(IO, "count ~p~n", [erlang:system_info(process_count)]),
    ok = io:format(IO, "memory ~p~n", [erlang:memory()]),
    ok = file:write(IO, erlang:system_info(procs)).

rm_rf(Name) when is_list(Name) ->
  case filelib:is_dir(Name) of
    false ->
      file:delete(Name);
    true ->
      case file:list_dir(Name) of
          {ok, Filenames} ->
              lists:foreach(
                fun rm_rf/1,
                [filename:join(Name, F) || F <- Filenames]),
              file:del_dir(Name);
          {error, Reason} ->
              ?log_info("rm_rf failed because ~p", [Reason])
      end
  end.

space_split(Bin) ->
    byte_split(Bin, 32). % ASCII space is 32.

zero_split(Bin) ->
    byte_split(Bin, 0).

byte_split(Bin, C) ->
    byte_split(0, Bin, C).

byte_split(N, Bin, _C) when N > erlang:byte_size(Bin) -> Bin;

byte_split(N, Bin, C) ->
    case Bin of
        <<_:N/binary, C:8, _/binary>> -> split_binary(Bin, N);
        _ -> byte_split(N + 1, Bin, C)
    end.

rand_str(N) ->
  lists:map(fun(_I) ->
      random:uniform(26) + $a - 1
    end, lists:seq(1,N)).

nthreplace(N, E, List) ->
  lists:sublist(List, N-1) ++ [E] ++ lists:nthtail(N, List).

nthdelete(N, List)        -> nthdelete(N, List, []).
nthdelete(0, List, Ret)   -> lists:reverse(Ret) ++ List;
nthdelete(_, [], Ret)     -> lists:reverse(Ret);
nthdelete(1, [_E|L], Ret) -> nthdelete(0, L, Ret);
nthdelete(N, [E|L], Ret)  -> nthdelete(N-1, L, [E|Ret]).

floor(X) ->
  T = erlang:trunc(X),
  case (X - T) of
    Neg when Neg < 0 -> T - 1;
    Pos when Pos > 0 -> T;
    _ -> T
  end.

ceiling(X) ->
  T = erlang:trunc(X),
  case (X - T) of
    Neg when Neg < 0 -> T;
    Pos when Pos > 0 -> T + 1;
    _ -> T
  end.

succ([])  -> [];
succ(Str) -> succ_int(lists:reverse(Str), []).

succ_int([Char|Str], Acc) ->
  if
    Char >= $z -> succ_int(Str, [$a|Acc]);
    true -> lists:reverse(lists:reverse([Char+1|Acc]) ++ Str)
  end.

fast_acc(_, Acc, 0)   -> Acc;
fast_acc(Fun, Acc, N) -> fast_acc(Fun, Fun(Acc), N-1).

hash(Term) ->
  ?prof(hash),
  R = fnv(Term),
  ?forp(hash),
  R.

hash(Term, Seed) -> hash({Term, Seed}).

% 32 bit fnv. magic numbers ahoy
fnv(Term) when is_binary(Term) ->
  fnv_int(?FNV_OFFSET_BASIS, 0, Term);

fnv(Term) ->
  fnv_int(?FNV_OFFSET_BASIS, 0, term_to_binary(Term)).

fnv_int(Hash, ByteOffset, Bin) when erlang:byte_size(Bin) == ByteOffset ->
  Hash;

fnv_int(Hash, ByteOffset, Bin) ->
  <<_:ByteOffset/binary, Octet:8, _/binary>> = Bin,
  Xord = Hash bxor Octet,
  fnv_int((Xord * ?FNV_PRIME) rem (2 bsl 31), ByteOffset+1, Bin).

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

byte_size(List) when is_list(List) ->
  lists:foldl(fun(El, Acc) -> Acc + ?MODULE:byte_size(El) end, 0, List);

byte_size(Term) ->
  erlang:byte_size(Term).

listify(List) when is_list(List) ->
  List;

listify(El) -> [El].

reverse_bits(V) when is_integer(V) ->
  % swap odd and even bits
  V1 = ((V bsr 1) band 16#55555555) bor
        (((V band 16#55555555) bsl 1) band 16#ffffffff),
  % swap consecutive pairs
  V2 = ((V1 bsr 2) band 16#33333333) bor
        (((V1 band 16#33333333) bsl 2) band 16#ffffffff),
  % swap nibbles ...
  V3 = ((V2 bsr 4) band 16#0F0F0F0F) bor
        (((V2 band 16#0F0F0F0F) bsl 4) band 16#ffffffff),
  % swap bytes
  V4 = ((V3 bsr 8) band 16#00FF00FF) bor
        (((V3 band 16#00FF00FF) bsl 8) band 16#ffffffff),
  % swap 2-byte long pairs
  ((V4 bsr 16) band 16#ffffffff) bor ((V4 bsl 16) band 16#ffffffff).

load_start_apps([]) -> ok;

load_start_apps([App | Apps]) ->
  case application:load(App) of
    ok -> case application:start(App) of
              ok  -> load_start_apps(Apps);
              Err -> io:format("error starting ~p: ~p~n", [App, Err]),
                     timer:sleep(10),
                     halt(1)
          end;
    Err -> io:format("error loading ~p: ~p~n", [App, Err]),
           Err,
           timer:sleep(10),
           halt(1)
  end.

running(Node, Module) ->
  Ref = erlang:monitor(process, {Module, Node}),
  R = receive
          {'DOWN', Ref, _, _, _} -> false
      after 1 ->
          true
      end,
  erlang:demonitor(Ref),
  R.

running(Pid) ->
  Ref = erlang:monitor(process, Pid),
  R = receive
          {'DOWN', Ref, _, _, _} -> false
      after 1 ->
          true
      end,
  erlang:demonitor(Ref),
  R.

running_nodes(Module) ->
  [Node || Node <- erlang:nodes([this, visible]), running(Node, Module)].

% Returns just the node name string that's before the '@' char.
% For example, returns "test" instead of "test@myhost.com".
%
node_name_short() ->
    [NodeName | _] = string:tokens(atom_to_list(node()), "@"),
    NodeName.

% Node is an atom like some_name@host.foo.bar.com

node_name_host(Node) ->
    [Name, Host | _] = string:tokens(atom_to_list(Node), "@"),
    {Name, Host}.

% Get an application environment variable, or a defualt value.
get_env_default(Var, Def) ->
    case application:get_env(Var) of
        {ok, Value} -> Value;
        undefined -> Def
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
    ok = file:write_file(PidFile, list_to_binary(Pid ++ "\n")),
    ok.

ping_jointo() ->
    case application:get_env(jointo) of
        {ok, NodeName} -> ping_jointo(NodeName);
        X -> X
    end.

ping_jointo(NodeName) ->
    ?log_info("jointo: attempting to contact ~p", [NodeName]),
    case net_adm:ping(NodeName) of
        pong -> ?log_info("jointo: connected to ~p", [NodeName]);
        pang -> {error, io_lib:format("jointo: could not ping ~p~n", [NodeName])}
    end.

mapfilter(F, Ref, List) ->
    lists:foldr(fun (Item, Acc) ->
                    case F(Item) of
                    Ref -> Acc;
                    Value -> [Value|Acc]
                    end
                 end, [], List).

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

wait_for_process(Pid, Timeout) ->
    Me = self(),
    Signal = make_ref(),
    spawn(fun() ->
                  process_flag(trap_exit, true),
                  link(Pid),
                  erlang:monitor(process, Me),
                  receive _ -> Me ! Signal end
          end),
    receive Signal -> ok
    after Timeout -> {error, timeout}
    end.

wait_for_process_test() ->
    %% Normal
    ok = wait_for_process(spawn(fun() -> ok end), 100),
    %% Timeout
    {error, timeout} = wait_for_process(spawn(fun() ->
                                                      timer:sleep(100), ok end),
                                        1),
    %% Process that exited before we went.
    Pid = spawn(fun() -> ok end),
    ok = wait_for_process(Pid, 100),
    ok = wait_for_process(Pid, 100).

spawn_link_safe(Fun) ->
    spawn_link_safe(node(), Fun).

spawn_link_safe(Node, Fun) ->
    Me = self(),
    Ref = make_ref(),
    spawn_link(
      Node,
      fun () ->
              process_flag(trap_exit, true),
              SubPid = Fun(),
              Me ! {Ref, pid, SubPid},
              receive
                  Msg -> Me ! {Ref, Msg}
              end
      end),
    receive
        {Ref, pid, SubPid} ->
            {ok, SubPid, Ref}
    end.


spawn_and_wait(Fun) ->
    spawn_and_wait(node(), Fun).

spawn_and_wait(Node, Fun) ->
    {ok, _Pid, Ref} = spawn_link_safe(Node, Fun),
    receive
        {Ref, Reason} ->
            Reason
    end.

%% Like proc_lib:start_link but allows to specify a node to spawn a process on.
-spec start_link(node(), module(), atom(), [any()]) -> any() | {error, term()}.
start_link(Node, M, F, A)
  when is_atom(Node), is_atom(M), is_atom(F), is_list(A) ->
    Pid = proc_lib:spawn_link(Node, M, F, A),
    sync_wait(Pid).

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
        _ -> ok
    end;
poll_for_condition_rec(Condition, Sleep, Counter) ->
    case Condition() of
        false ->
            timer:sleep(Sleep),
            poll_for_condition_rec(Condition, Sleep, Counter-1);
        _ -> ok
    end.

poll_for_condition(Condition, Timeout, Sleep) ->
    Times = (Timeout + Sleep - 1) div Sleep,
    poll_for_condition_rec(Condition, Sleep, Times).

poll_for_condition_test() ->
    ok = poll_for_condition(fun () -> true end, 0, 10),
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
    ok = poll_for_condition(Fun, 300, 10),
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

flush_head(Head) ->
    flush_head(Head, 0).

flush_head(Head, N) ->
    receive
        Msg when element(1, Msg) == Head ->
            flush_head(Head, N+1)
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

keymin(I, [H|T]) ->
    keymin(I, T, H).

keymin(_, [], M) ->
    M;
keymin(I, [H|T], M) ->
    case element(I, H) < element(I, M) of
        true ->
            keymin(I, T, H);
        false ->
            keymin(I, T, M)
    end.

keymin_test() ->
    {c, 3} = keymin(2, [{a, 5}, {c, 3}, {d, 10}]).

keymax(I, [H|T]) ->
    keymax(I, T, H).

keymax(_, [], M) ->
    M;
keymax(I, [H|T], M) ->
    case element(I, H) > element(I, M) of
        true ->
            keymax(I, T, H);
        false ->
            keymax(I, T, M)
    end.

keymax_test() ->
    {20, g} = keymax(1, [{5, d}, {19, n}, {20, g}, {15, z}]).

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


pairs([H1|[H2|_] = T]) ->
    [{H1, H2}|pairs(T)];
pairs([_]) ->
    [];
pairs([]) ->
    [].

pairs_test() ->
    [{1,2}, {2,3}, {3,4}] = pairs([1,2,3,4]),
    [] = pairs([]),
    [{1,2}, {2,3}] = pairs([1,2,3]),
    [] = pairs([1]),
    [{1,2}] = pairs([1,2]).



rewrite_value(Old, New, Old) ->
    New;
rewrite_value(Old, New, L) when is_list(L) ->
    lists:map(fun (V) -> rewrite_value(Old, New, V) end, L);
rewrite_value(Old, New, T) when is_tuple(T) ->
    list_to_tuple(rewrite_value(Old, New, tuple_to_list(T)));
rewrite_value(_Old, _New, X) -> X.

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
         {"b string", 4, b, {blah, b, b}}].


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
            ?log_info("start_singleton(~p, ~p, ~p, ~p):"
                      " monitoring ~p from ~p",
                      [Module, Name, Args, Opts, Pid, node()]),
            {ok, spawn_link(fun () ->
                                    misc:wait_for_process(Pid, infinity),
                                    ?log_info("~p saw ~p exit (was pid ~p).",
                                              [self(), Name, Pid])
                            end)};
        {ok, Pid} = X ->
            ?log_info("start_singleton(~p, ~p, ~p, ~p):"
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

%% Retry a function that returns either N times
retry(F) -> retry(F, 3).
retry(F, N) -> retry(F, N, initial_error).

%% Implementation below.
%% These wouldn't be exported if it werent for export_all
retry(_F, 0, Error) -> exit(Error);
retry(F, N, _Error) ->
    case catch(F()) of
        {'EXIT',X} -> retry(F, N - 1, X);
        Success -> Success
    end.

retry_test() ->
    %% Positive cases.
    ok = retry(fun () -> ok end),
    {ok, 1827841} = retry(fun() -> {ok, 1827841} end),

    %% Error cases.
    case (catch retry(fun () -> exit(foo) end)) of
        {'EXIT', foo} ->
            ok
    end,

    %% Verify a retry with a function that will succeed the second
    %% time.
    self() ! {testval, a},
    self() ! {testval, b},
    self() ! {testval, c},
    self() ! {testval, d},
    b = retry(fun () -> b = receive {testval, X} -> X end end).


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
    case file:read(File, 10) of
        {ok, Bytes} ->
            raw_read_loop(File, [Acc | Bytes]);
        eof ->
            file:close(File),
            {ok, iolist_to_binary(Acc)};
        {error, Reason} ->
            file:close(File),
            erlang:error(Reason)
    end.

multicall_result_to_plist_rec([], _ResL, _BadNodes, Acc) ->
    Acc;
multicall_result_to_plist_rec([N | Nodes], Results, BadNodes,
                              {SuccessAcc, ErrorAcc} = Acc) ->
    case lists:member(N, BadNodes) of
        true ->
            multicall_result_to_plist_rec(Nodes, Results, BadNodes, Acc);
        _ ->
            [Res | ResRest] = Results,

            case Res of
                {badrpc, Reason} ->
                    NewAcc = {SuccessAcc, [{N, Reason} | ErrorAcc]},
                    multicall_result_to_plist_rec(Nodes, ResRest, BadNodes,
                                                  NewAcc);
                _ ->
                    NewAcc = {[{N, Res} | SuccessAcc], ErrorAcc},
                    multicall_result_to_plist_rec(Nodes, ResRest, BadNodes, NewAcc)
            end
    end.

%% Returns a pair of proplists. First one is a mapping from Nodes to return
%% values for nodes that succeeded. Second one is a mapping from Nodes to
%% error reason for failed nodes.
multicall_result_to_plist(Nodes, {ResL, BadNodes}) ->
    multicall_result_to_plist_rec(Nodes, ResL, BadNodes, {[], []}).

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

zipwith4(_Combine, [], [], [], []) -> [];
zipwith4(Combine, List1, List2, List3, List4) ->
    [Combine(hd(List1), hd(List2), hd(List3), hd(List4))
     | zipwith4(Combine, tl(List1), tl(List2), tl(List3), tl(List4))].

zipwith4_test() ->
    F = fun (A1, A2, A3, A4) -> {A1, A2, A3, A4} end,

    Actual1 = zipwith4(F, [1, 1, 1], [2,2,2], [3,3,3], [4,4,4]),
    Actual1 = lists:duplicate(3, {1,2,3,4}),

    case (catch {ok, zipwith4(F, [1,1,1], [2,2,2], [3,3,3], [4,4,4,4])}) of
        {ok, _} ->
            exit(bad_error_handling);
        _ -> ok
    end.

-spec split_binary_at_char(binary(), char()) -> binary() | {binary(), binary()}.
split_binary_at_char(Binary, Chr) ->
    case binary:split(Binary, <<Chr:8>>) of
        [_] -> Binary;
        [Part1, Part2] -> {Part1, Part2}
    end.


%% Quick function to build the ebucketmigrator escript, partially copied from
%% https://bitbucket.org/basho/rebar/src/d4fcc10abc0b/src/rebar_escripter.erl
build_ebucketmigrator() ->

    Filename = "ebucketmigrator",
    Modules = [ebucketmigrator, ebucketmigrator_srv,
               mc_client_binary, mc_binary, misc],
    Files = [read_beam(Mod, "ebin") || Mod <- Modules],

    AleDir = filename:join(["deps", "ale", "ebin"]),
    AleModules = [ale, ale_sup, ale_dynamic_sup, ale_stderr_sink,
                  ale_default_formatter, ale_utils, ale_codegen,
                  ale_error_logger_handler, dynamic_compile],
    AleFiles = [read_beam(Mod, AleDir) || Mod <- AleModules],

    Files1 = Files ++ AleFiles,

    case zip:create("mem", Files1, [memory]) of
        {ok, {"mem", ZipBin}} ->
            Script = <<"#!/usr/bin/env escript\n", ZipBin/binary>>,
            case file:write_file(Filename, Script) of
                ok ->
                    ok;
                {error, WriteError} ->
                    throw({write_failed, WriteError})
            end;
        {error, ZipError} ->
            throw({build_script_files, ZipError})
    end,

    {ok, #file_info{mode = Mode}} = file:read_file_info(Filename),
    ok = file:change_mode(Filename, Mode bor 8#00100),
    ok.

read_beam(Module, Dir) ->
    Filename = atom_to_list(Module) ++ ".beam",
    {Filename, file_contents(filename:join(Dir, Filename))}.

file_contents(Filename) ->
    {ok, Bin} = file:read_file(Filename),
    Bin.

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

%% Return a list containing all but the last elements of the source list.
-spec init(nonempty_list()) -> list().
init([_X]) ->
    [];
init([X | Rest]) ->
    [X | init(Rest)].

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
    node_rest_port(ns_config:get(), Node).

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
-endif.

%% Writes to file atomically using write_file + rename trick.
%% NB: this does not work on Windows
%% (http://osdir.com/ml/racket.development/2011-01/msg00149.html).
atomic_write_file(Path, Contents) ->
    TmpPath = Path ++ ".tmp",
    case file:write_file(TmpPath, Contents) of
        ok ->
            file:rename(TmpPath, Path);
        X -> X
    end.
