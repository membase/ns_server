-module(addr_util).

-export([get_my_address/0]).

%% Find the best IP address we can find for the current host.
get_my_address() ->
    {ok, AddrInfo} = inet:getif(),
    Addr = extract_addr(
             lists:sort(
               lists:map(fun({A,_,_}) -> A end, AddrInfo))
             -- [{127,0,0,1}]), %% 127.0.0.1 is a special case.
    addr_to_s(Addr).

%% [{1,2,3,4},...] -> {1,2,3,4}
extract_addr([H|_Tl]) ->
    H;
%% [] -> {127,0,0,1}
extract_addr([]) ->
    {127,0,0,1}.

%% {1,2,3,4} -> "1.2.3.4"
addr_to_s(T) ->
    string:join(lists:map(fun erlang:integer_to_list/1,
                          tuple_to_list(T)),
                ".").
