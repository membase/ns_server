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

-export([new/1, to_list/1, to_list/2, to_list/3, add/2]).

% Create a ringbuffer that can hold at most Size items.
-spec new(integer()) -> queue().
new(Size) ->
    queue:from_list([empty || _ <- lists:seq(1, Size)]).


% Convert the ringbuffer to a list (oldest items first).
-spec to_list(integer()) -> list().
to_list(R) -> to_list(R, false).
-spec to_list(queue(), W) -> list() when is_subtype(W, boolean());
             (integer(), queue()) -> list().
to_list(R, WithEmpties) when is_boolean(WithEmpties) ->
    queue:to_list(to_queue(R));

% Get at most the N newest items from the given ringbuffer (oldest first).
to_list(N, R) -> to_list(N, R, false).

-spec to_list(integer(), queue(), boolean()) -> list().
to_list(N, R, WithEmpties) ->
    L =  lists:reverse(queue:to_list(to_queue(R, WithEmpties))),
    lists:reverse(case (catch lists:split(N, L)) of
                      {'EXIT', {badarg, _Reason}} -> L;
                      {L1, _L2} -> L1
                  end).

% Add an element to a ring buffer.
-spec add(term(), queue()) -> queue().
add(E, R) ->
    queue:in(E, queue:drop(R)).

% private
-spec to_queue(queue()) -> queue().
to_queue(R) -> to_queue(R, false).

-spec to_queue(queue(), boolean()) -> queue().
to_queue(R, false) -> queue:filter(fun(X) -> X =/= empty end, R);
to_queue(R, true) -> R.
