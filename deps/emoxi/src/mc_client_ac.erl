-module(mc_client_ac).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{cmd,5}];
behaviour_info(_Other) ->
    undefined.
