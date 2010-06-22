-module(eshell).
-export([eval/2]).
eval(Str,Binding) ->
    {ok,Ts,_} = erl_scan:string(Str),
    Ts1 = case lists:reverse(Ts) of
              [{dot,_}|_] -> Ts;
              TsR -> lists:reverse([{dot,1} | TsR])
          end,
    {ok,Expr} = erl_parse:parse_exprs(Ts1),
    erl_eval:exprs(Expr, Binding).
