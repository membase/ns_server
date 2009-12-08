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
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(storage_dets).

%% API
-export([open/2, close/1, get/2, put/4, has_key/2, delete/2, fold/3]).

-record(row, {key, context, values}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec
%% @doc
%% @end
%%--------------------------------------------------------------------

open(Directory, Name) ->
  ok = filelib:ensure_dir(Directory ++ "/"),
  TableName = list_to_atom(lists:concat([Name, '/', node()])),
  dets:open_file(TableName,
                 [{file, lists:concat([Directory, "/storage.dets"])},
                  {keypos, 2}]).

close(Table) -> dets:close(Table).

fold(Fun, Table, AccIn) when is_function(Fun) ->
  dets:foldl(fun(#row{key=Key,context=Context,values=Values}, Acc) ->
      Fun({Key, Context, Values}, Acc)
    end, AccIn, Table).

put(Key, Context, Values, Table) ->
  case dets:insert(Table, [#row{key=Key,context=Context,values=Values}]) of
    ok -> {ok, Table};
    Failure -> Failure
  end.

get(Key, Table) ->
  case dets:lookup(Table, Key) of
    [] -> {ok, not_found};
    [#row{context=Context,values=Values}] -> {ok, {Context, Values}}
  end.

has_key(Key, Table) ->
  case dets:member(Table, Key) of
    true -> {ok, true};
    false -> {ok, false};
    Failure -> Failure
  end.

delete(Key, Table) ->
  case dets:delete(Table, Key) of
    ok -> {ok, Table};
    Failure -> Failure
  end.

