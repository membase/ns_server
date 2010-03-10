%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(ringdict).

-export([new/1, to_dict/1, to_dict/2, to_dict/3, add/2]).

-record(rdict, {d, size}).

% Convert a ringdict that can hold at most Size items.
-spec new(integer()) -> #rdict{}.
new(Size) ->
    #rdict{d=dict:new(), size=Size}.

% Convert this ringdict to a regular dict (values as lists with the
% oldest items first).
-spec to_dict(#rdict{}) -> dict().
to_dict(R) -> to_dict(R, false).

-spec to_dict(#rdict{}, W) -> dict() when is_subtype(W, boolean());
             (integer(), #rdict{}) -> dict().
to_dict(R, WithEmpties) when is_boolean(WithEmpties) ->
    dict:map(fun (_K, V) -> ringbuffer:to_list(V, WithEmpties) end, R#rdict.d);

% Convert this ringdict to a regular dict (values as lists with the
% oldest items first) with no more than N newest items.
to_dict(N, R) -> to_dict(N, R, false).

-spec to_dict(integer(), #rdict{}, boolean()) -> dict().
to_dict(N, R, WithEmpties) ->
    dict:map(fun (_K, V) -> ringbuffer:to_list(N, V, WithEmpties) end, R#rdict.d).

% Add a dictionary to a ringdict.
-spec add(dict(), #rdict{}) -> #rdict{}.
add(D, R) ->
    R#rdict{d=dict:fold(fun (K, V, Din) -> append_to_rdict(K, V, R, Din) end,
                        R#rdict.d, D)}.

append_to_rdict(K, V, R, Din) ->
    try dict:update(K, fun(Rin) -> ringbuffer:add(V, Rin) end, Din)
    catch _:_ -> dict:store(K,
                            ringbuffer:add(V, ringbuffer:new(R#rdict.size)),
                            Din)
    end.
