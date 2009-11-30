-module(mc_config).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

lookup(Key, KVList) -> lookup(Key, KVList, undefined).
lookup(_Key, [], Default) -> Default;
lookup(Key, [{K, V} | Rest], Default) ->
    case Key =:= K of
        true  -> V;
        false ->lookup(Key, Rest, Default)
    end.
