-module(ecukes).

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
    Tokens = string:tokens(string:to_lower(Line), " "),
    Atoms = lists:map(fun list_to_atom/1, Tokens),
    {Mode2, GWT2, Result} =
        case {Mode, Atoms} of
            {_, ['feature:' | _]}  ->
                {feature, undefined, undefined};
            {_, ['scenario:' | _]} ->
                {scenario, undefined, undefined};
            {_, []}                ->
                {undefined, undefined, undefined};
            {undefined, _}         ->
                {undefined, undefined, undefined};
            {scenario, [AtomsHead | AtomsTail]} ->
                G = case {GWT, AtomsHead} of
                        {undefined, _}   -> AtomsHead;
                        {_, 'and'}       -> GWT;
                        {GWT, AtomsHead} -> AtomsHead
                    end,
                R = lists:foldl(
                      fun (SM, Acc) ->
                              case Acc of
                                  true  -> Acc;
                                  false ->
                                      S = SM:step([G, AtomsTail], Line),
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

