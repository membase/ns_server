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

-define(FNV_OFFSET_BASIS, 2166136261).
-define(FNV_PRIME,        16777619).

-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-define(prof(Label), true).
-define(forp(Label), true).
-define(balance_prof, true).

-ifdef(TEST).
-include("test/misc_test.erl").
-endif.

shuffle(List) when is_list(List) ->
    [N || {_R, N} <- lists:keysort(1, [{random:uniform(), X} || X <- List])].

pmap(Fun, List, ReturnNum) ->
    ?MODULE:pmap(Fun, List, ReturnNum, infinity).

pmap(Fun, List, ReturnNum, Timeout) ->
    C = length(List),
    N = case ReturnNum > C of
            true  -> C;
            false -> ReturnNum
        end,
    SuperParent = self(),
    SuperRef = erlang:make_ref(),
    Ref = erlang:make_ref(),
    %% Spawn an intermediary to collect the results this is so that
    %% there will be no leaked messages sitting in our mailbox.
    Parent = spawn(fun () ->
                       L = gather(N, length(List), Ref, []),
                       SuperParent ! {SuperRef, pmap_sort(List, L)}
                   end),
    Pids = [spawn(fun () ->
                      Ret = (catch Fun(Elem)),
                      Parent ! {Ref, {Elem, Ret}}
                  end) || Elem <- List],
    Ret2 = receive
              {SuperRef, Ret} -> Ret
           after Timeout ->
              {error, timeout}
           end,
    % TODO: Need cleanup here?
    lists:foreach(fun(P) -> exit(P, die) end, Pids),
    Ret2.

pmap_sort(Original, Results) ->
    pmap_sort([], Original, lists:reverse(Results)).

pmap_sort(Sorted, _, []) -> lists:reverse(Sorted);
pmap_sort(Sorted, [E | Original], Results) ->
    case lists:keytake(E, 1, Results) of
        {value, {E, Val}, Rest} -> pmap_sort([Val | Sorted], Original, Rest);
        false                   -> pmap_sort(Sorted, Original, Results)
    end.

gather(_, Max, _, L) when length(L) >= Max -> L;
gather(0, _, _, L) -> L;
gather(N, Max, Ref, L) ->
    receive
        {Ref, {_Elem, {'EXIT', _}} = ElemRet} ->
            gather(N, Max, Ref, [ElemRet | L]);
        {Ref, ElemRet} ->
            gather(N - 1, Max, Ref, [ElemRet | L])
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
              error_logger:info_msg("rm_rf failed because ~p~n",
                                    [Reason])
      end
  end.

zero_split(Bin) ->
  zero_split(0, Bin).

zero_split(N, Bin) when N > erlang:byte_size(Bin) -> Bin;

zero_split(N, Bin) ->
  case Bin of
    <<_:N/binary, 0:8, _/binary>> -> split_binary(Bin, N);
    _ -> zero_split(N+1, Bin)
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

running(Node) ->
  Ref = erlang:monitor(process, {membership, Node}),
  R = receive
          {'DOWN', Ref, _, _, _} -> false
      after 1 ->
          true
      end,
  erlang:demonitor(Ref),
  R.

running_nodes() ->
  [Node || Node <- erlang:nodes([this, visible]), running(Node)].

