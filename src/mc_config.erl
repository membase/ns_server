-module(mc_config).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

lookup(Field, Config) ->
    lookup(Field, Config, undefined).

lookup(Field, [{Field, Val} | _], _Default) -> Val;
lookup(Field, [_ | Rest], Default)          -> lookup(Field, Rest, Default);
lookup(_Field, [], Default)                  -> Default.

