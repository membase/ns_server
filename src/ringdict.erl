-module(ringdict).

-export([new/1, to_dict/1, to_dict/2, add/2]).

-record(rdict, {d, size}).

% Convert a ringdict that can hold at most Size items.
-spec new(integer()) -> #rdict{}.
new(Size) ->
    #rdict{d=dict:new(), size=Size}.

% Convert this ringdict to a regular dict (values as lists with the
% oldest items first).
-spec to_dict(#rdict{}) -> dict().
to_dict(R) ->
    dict:map(fun (_K, V) -> ringbuffer:to_list(V) end, R#rdict.d).

% Convert this ringdict to a regular dict (values as lists with the
% oldest items first) with no more than N newest items.
-spec to_dict(integer(), #rdict{}) -> dict().
to_dict(N, R) ->
    dict:map(fun (_K, V) -> ringbuffer:to_list(N, V) end, R#rdict.d).

% Add a dictionary to a ringdict.
-spec add(dict(), #rdict{}) -> #rdict{}.
add(D, R) ->
    R#rdict{d=dict:fold(fun (K, V, Din) ->
                                dict:update(K, fun(Rin) ->
                                                       ringbuffer:add(V, Rin)
                                               end,
                                            ringbuffer:add(V, ringbuffer:new(R#rdict.size)),
                                            Din)
                        end,
                        R#rdict.d, D)}.
