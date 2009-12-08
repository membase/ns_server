% Copyright (c) 2009, NorthScale, Inc
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

-module (storage_dict).

-export ([open/2, close/1, get/2, put/4, has_key/2,
          fold/3, delete/2, info/1]).

open(_, _)    -> {ok, dict:new()}.
close(_Table) -> ok.
info(Table)   -> dict:fetch_keys(Table).

fold(Fun, Table, AccIn) when is_function(Fun) ->
  dict:fold(fun(Key, {Context, [Value]}, Acc) ->
      Fun({Key, Context, Value}, Acc)
    end, AccIn, Table).

put(Key, Context, Value, Table) ->
  ToPut = if
    is_list(Value) -> Value;
    true -> [Value]
  end,
	{ok, dict:store(Key, {Context,ToPut}, Table)}.

get(Key, Table) ->
  case dict:find(Key, Table) of
    {ok, Value} -> {ok, Value};
    _ -> {ok, not_found}
  end.

has_key(Key, Table) -> {ok, dict:is_key(Key, Table)}.
delete(Key, Table)  -> {ok, dict:erase(Key, Table)}.
