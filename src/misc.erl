% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
% Copyright (c) 2009, NorthScale, Inc
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
% POSSIBILITY OF SUCH DAMAGE.-module(config).
%
% Original Author: Cliff Moon

-module(misc).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

shuffle(List) when is_list(List) ->
    [N || {_R, N} <- lists:keysort(1, [{random:uniform(), X} || X <- List])].

pmap(Fun, List, ReturnNum) ->
    L = length(List),
    N = case ReturnNum > L of
            true  -> L;
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
                      Parent ! {Ref, {Elem, (catch Fun(Elem))}}
                  end) || Elem <- List],
    Ret2 = receive
              {SuperRef, Ret} -> Ret
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

gather(_, Max, _, L) when length(L) == Max -> L;
gather(0, _, _, L) -> L;
gather(N, Max, Ref, L) ->
    receive
        {Ref, {Elem, {'EXIT', Ret}}} ->
            gather(N, Max, Ref, [{Elem, {'EXIT', Ret}} | L]);
        {Ref, Ret} ->
            gather(N - 1, Max, Ref, [Ret | L])
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
