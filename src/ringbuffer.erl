-module(ringbuffer).

-export([new/1, to_list/1, to_list/2, to_list/3, add/2]).

% Create a ringbuffer that can hold at most Size items.
-spec new(integer()) -> {list(), list()}.
new(Size) ->
    queue:from_list([empty || _ <- lists:seq(1, Size)]).


% Convert the ringbuffer to a list (oldest items first).
-spec to_list(integer()) -> list().
to_list(R) -> to_list(R, false).
-spec to_list({list(), list()}, W) -> list() when is_subtype(W, boolean());
             (integer(), {list(), list()}) -> list().
to_list(R, WithEmpties) when is_boolean(WithEmpties) ->
    queue:to_list(to_queue(R));

% Get at most the N newest items from the given ringbuffer (oldest first).
to_list(N, R) -> to_list(N, R, false).

-spec to_list(integer(), {list(), list()}, boolean()) -> list().
to_list(N, R, WithEmpties) ->
    L =  lists:reverse(queue:to_list(to_queue(R, WithEmpties))),
    lists:reverse(case (catch lists:split(N, L)) of
                      {'EXIT', {badarg, _Reason}} -> L;
                      {L1, _L2} -> L1
                  end).

% Add an element to a ring buffer.
-spec add(term(), {list(), list()}) -> {list(), list()}.
add(E, R) ->
    queue:in(E, queue:drop(R)).

% private
-spec to_queue({list(), list()}) -> {list(), list()}.
to_queue(R) -> to_queue(R, false).

-spec to_queue({list(), list()}, boolean()) -> {list(), list()}.
to_queue(R, false) -> queue:filter(fun(X) -> X =/= empty end, R);
to_queue(R, true) -> R.
