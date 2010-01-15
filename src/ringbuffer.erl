-module(ringbuffer).

-export([new/1, to_list/1, to_list/2, add/2]).

% Create a ringbuffer that can hold at most Size items.
new(Size) ->
    queue:from_list([empty || _ <- lists:seq(1, Size)]).

% Convert the ringbuffer to a list (oldest items first).
to_list(R) ->
    queue:to_list(to_queue(R)).

% Get at most the N newest items from the given ringbuffer (oldest first).
to_list(N, R) ->
    L =  lists:reverse(queue:to_list(to_queue(R))),
    lists:reverse(case (catch lists:split(N, L)) of
                      {'EXIT', {badarg, _Reason}} -> L;
                      {L1, _L2} -> L1
                  end).

% Add an element to a ring buffer.
add(E, R) ->
    queue:in(E, queue:drop(R)).

% private

to_queue(R) ->
    queue:filter(fun(X) -> X =/= empty end, R).
