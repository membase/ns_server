%% Copyright (c) 2012 Couchbase, Inc.
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
%%

-module(file_util).

-include_lib("kernel/include/file.hrl").

-export([remove/3]).

%% Older versions of lists:nthtail crash on N where N > length of the
%% list.  The newer version returns an empty list.  As there are mixed
%% deployments, I copied the newer version implementation here.
nthtail(0, A) -> A;
nthtail(N, [_ | A]) -> nthtail(N-1, A);
nthtail(_, _) -> [].

%% Remove the oldest N files from the given directory that match the
%% given prefix.
-spec remove(string(), string(), pos_integer()) -> integer().
remove(Dir, Prefix, N) ->
    {ok, Names} = file:list_dir(Dir),

    AbsNames = [filename:join(Dir, Fn) || Fn <- Names,
                                          string:str(Fn, Prefix) == 1],

    TimeList = lists:map(fun(Fn) ->
                      {ok, Fi} = file:read_file_info(Fn),
                                 {Fn, Fi#file_info.mtime}
                         end, AbsNames),

    Sorted = lists:reverse(lists:keysort(2, TimeList)),

    Oldest = [Fn || {Fn, _} <- nthtail(N, Sorted)],

    lists:foldl(fun(Fn, I) -> ok = file:delete(Fn), I + 1 end, 0, Oldest).
