-module(mc_client).

-export([behaviour_info/1]).

behaviour_info(callbacks) ->
    [{cmd,5}, {auth,2}];
behaviour_info(_Other) ->
    undefined.
