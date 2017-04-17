%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ringbuffer).

-export([new/1, to_list/1, add/2]).

% Create a ringbuffer that can hold at most Size items.
-spec new(integer()) -> queue().
new(Size) ->
    queue:from_list([empty || _ <- lists:seq(1, Size)]).


% Convert the ringbuffer to a list (oldest items first).
-spec to_list(queue()) -> list().
to_list(R) ->
    queue:to_list(queue:filter(fun(X) -> X =/= empty end, R)).

% Add an element to a ring buffer.
-spec add(term(), queue()) -> queue().
add(E, R) ->
    queue:in(E, queue:drop(R)).
