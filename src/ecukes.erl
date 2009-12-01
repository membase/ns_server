-module(ecukes).

-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

% Subset of cucumber/gherkin parser & driver in erlang.
%
% Example step implementation pattern...
%
% step([given, i, have, already, installed, the, _Product], _Line) ->
%     % Your step implementation here.
%     true;
%
% Example call...
%
% ecukes:cucumber("./features/sample.feature").
%
cucumber(FilePath)              -> cucumber(FilePath, []).
cucumber(FilePath, StepModules) -> cucumber(FilePath, StepModules, 1).
cucumber(FilePath, StepModules, StartNum) ->
    StepModulesX = StepModules ++ [?MODULE],
    Lines = lines(FilePath),
    cucumber_lines(Lines, StepModulesX, StartNum).

cucumber_lines(Lines, StepModules, StartNum) ->
    lists:foldl(
      fun (Line, {Mode, GWT, LineNum} = Acc) ->
          case LineNum >= StartNum of
              true  -> process_line(Line, Acc, StepModules);
              false -> {Mode, GWT, LineNum + 1}
          end
      end,
      {undefined, undefined, 1}, Lines).

process_line(Line, {Mode, GWT, LineNum}, StepModules) ->
    % GWT stands for given-when-then.
    % GWT is the previous line's given-when-then atom.
    io:format("~s:~s ",
              [string:left(Line, 59),
               string:left(integer_to_list(LineNum), 4)]),
    % Handle quoted sections by spliting by "\"" first.
    {TokenStrs, QuotedStrs} =
        unzip_odd_even(string:tokens(Line, "\"")),
    % Atomize the unquoted sections.
    TokenAtoms =
      lists:map(fun (X) ->
                    lists:map(fun (Y) ->
                                  list_to_atom(string:to_lower(Y))
                              end,
                              string:tokens(X, " "))
                end,
                TokenStrs),
    Tokens = zip_odd_even(TokenAtoms, QuotedStrs, 1, []),
    {Mode2, GWT2, Result} =
        case {Mode, Tokens} of
            {_, ['feature:' | _]}  ->
                {feature, undefined, undefined};
            {_, ['scenario:' | _]} ->
                {scenario, undefined, undefined};
            {_, []}                ->
                {undefined, undefined, undefined};
            {undefined, _}         ->
                {undefined, undefined, undefined};
            {scenario, [TokensHead | TokensTail]} ->
                G = case {GWT, TokensHead} of
                        {undefined, _}    -> TokensHead;
                        {_, 'and'}        -> GWT;
                        {GWT, TokensHead} -> TokensHead
                    end,
                R = lists:foldl(
                      fun (SM, Acc) ->
                              case Acc of
                                  true  -> Acc;
                                  false ->
                                      S = SM:step([G | TokensTail], Line),
                                      S =/= undefined
                              end
                      end,
                      false, StepModules),
                {Mode, G, R}
        end,
    case {Mode2, Result} of
        {scenario, true}  -> io:format("ok~n");
        {scenario, false} -> io:format("NO-STEP~n");
        _                 -> io:format("~n")
    end,
    {Mode2, GWT2, LineNum + 1}.

step(['feature:' | _], _Line)  -> true;
step(['scenario:' | _], _Line) -> true;
step([], _) -> true;
step(_, _)  -> undefined.

lines(FilePath) ->
    {ok, FB} = file:read_file(FilePath),
    lines(binary_to_list(FB), [], []).

lines([], CurrLine, Lines) ->
    lists:reverse([lists:reverse(CurrLine) | Lines]);
lines([$\n | Rest], CurrLine, Lines) ->
    lines(Rest, [], [lists:reverse(CurrLine) | Lines]);
lines([X | Rest], CurrLine, Lines) ->
    lines(Rest, [X | CurrLine], Lines).

% Also does flattening of Odds.

zip_odd_even([], [], _F, Acc) ->
    lists:reverse(Acc);
zip_odd_even([], [Even | Evens], F, Acc) ->
    zip_odd_even([], Evens, F, [Even | Acc]);
zip_odd_even([Odd | Odds], [], F, Acc) ->
    zip_odd_even(Odds, [], F, lists:reverse(Odd) ++ Acc);
zip_odd_even([Odd | Odds], Evens, 1, Acc) ->
    zip_odd_even(Odds, Evens, 0, lists:reverse(Odd) ++ Acc);
zip_odd_even(Odds, [Even | Evens], 0, Acc) ->
    zip_odd_even(Odds, Evens, 1, [Even | Acc]).

unzip_odd_even(Tokens) ->
    {Odds, Evens, _F} =
        lists:foldl(fun (X, {Odds, Evens, F}) ->
                        case F of
                            1 -> {[X | Odds], Evens, 0};
                            0 -> {Odds, [X | Evens], 1}
                        end
                    end,
                    {[], [], 1},
                    Tokens),
    {lists:reverse(Odds), lists:reverse(Evens)}.
