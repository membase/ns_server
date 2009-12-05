-module(util).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

shuffle(List) when is_list(List) ->
    [N || {_R, N} <- lists:keysort(1, [{random:uniform(), X} || X <- List])].

