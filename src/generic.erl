%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2018 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(generic).

-include("generic.hrl").
-include("triq.hrl").

-export([transformb/2, transformb/3,
         transformt/2, transformt/3,
         universe/1, universe/2,
         maybe_transform/2, maybe_transform/3,
         query/3]).

%% Apply a transformation everywhere in bottom-up manner.
transformb(Fun, State, Term) ->
    {NewTerm, NewState} = gmap(fun (T, S) ->
                                       transformb(Fun, S, T)
                               end, State, Term),
    Fun(NewTerm, NewState).

transformb(Fun, Term) ->
    ignoring_state(fun transformb/3, Fun, Term).

%% Apply a transformation everywhere in top-down manner.
transformt(Fun, State, Term) ->
    maybe_transform(fun (T, S) ->
                            {NewT, NewS} = Fun(T, S),
                            {continue, NewT, NewS}
                    end, State, Term).

transformt(Fun, Term) ->
    ignoring_state(fun transformt/3, Fun, Term).

%% Return the subterms matching a predicate.
matching(Pred, Term) ->
    matching(Pred, Term, fun transformb/3).

matching(Pred, Term, Traversal) ->
    {_, Result} =
        Traversal(fun (T, Acc) ->
                          NewAcc = case Pred(T) of
                                       true ->
                                           [T | Acc];
                                       false ->
                                           Acc
                                   end,
                          {T, NewAcc}
                  end, [], Term),
    lists:reverse(Result).

%% Return all possible subterms.
universe(Term) ->
    universe(Term, fun transformb/3).

universe(Term, Traversal) ->
    matching(functools:const(true), Term, Traversal).

%% Apply a transformation everywhere in top-down manner. The 'Fun'
%% function may choose to stop the recursive descent early by
%% returning {stop, ResultTerm, ResultState}. Note, there's not 't'
%% suffix here, because short-cutting doesn't make much sense in
%% bottom-up traversal.
maybe_transform(Fun, State, Term) ->
    case Fun(Term, State) of
        {continue, NewTerm, NewState} ->
            gmap(fun (T, S) ->
                         maybe_transform(Fun, S, T)
                 end, NewState, NewTerm);
        {stop, NewTerm, NewState} ->
            {NewTerm, NewState}
    end.

maybe_transform(Fun, Term) ->
    do_ignoring_state(fun maybe_transform/3,
                      fun (T, S) ->
                              {Action, NewT} = Fun(T),
                              {Action, NewT, S}
                      end, Term).

%% Run a query on the term. The 'Fun' is called on each element in the
%% term and these values are then recombined by 'K'. Ideally, 'K'
%% should not depend on the order of traversal, that is it has to be
%% associative and commutative.
query(K, Fun, Term) ->
    lists:foldl(K, Fun(Term),
                gmapq(fun (T) ->
                              query(K, Fun, T)
                      end, Term)).

%% internal
gfold(Fun, State, [H|T]) ->
    Fun([H, T], State,
        fun ([NewH, NewT]) ->
                [NewH | NewT]
        end);
gfold(Fun, State, Tuple) when is_tuple(Tuple) ->
    Fun(tuple_to_list(Tuple), State,
        fun (NewTupleList) ->
                NewTuple = list_to_tuple(NewTupleList),
                true = (tuple_size(Tuple) =:= tuple_size(NewTuple)),
                NewTuple
        end);
gfold(Fun, State, Term) ->
    Fun([], State,
        fun ([]) ->
                Term
        end).

%% Apply a transformation to direct childrent of a term.
gmap(Fun, State, Term) ->
    gfold(fun (Children, S, Recover) ->
                  {NewChildren, NewState} =
                      lists:foldl(
                        fun (Child, {AccChildren, AccS}) ->
                                {NewChild, NewAccS} = Fun(Child, AccS),
                                {[NewChild | AccChildren], NewAccS}
                        end, {[], S}, Children),
                  {Recover(lists:reverse(NewChildren)), NewState}
          end, State, Term).

%% Run a query on all direct children of a term. Return results in as
%% a list.
gmapq(Fun, Term) ->
    {Result, unused} = gfold(fun (Children, State, _Recover) ->
                                     {lists:map(Fun, Children), State}
                             end, unused, Term),
    Result.

ignoring_state(BaseFun, Fun, Term) ->
    do_ignoring_state(BaseFun,
                      fun (T, S) ->
                              {Fun(T), S}
                      end, Term).

do_ignoring_state(BaseFun, WrappedFun, Term) ->
    {NewTerm, unused} = BaseFun(WrappedFun, unused, Term),
    NewTerm.

%% test-related helpers
random_term([]) ->
    oneof([{}, []]);
random_term([X]) ->
    oneof([[X], {X}, X]);
random_term(Items) when is_list(Items) ->
    frequency([{2, Items},
               {2, list_to_tuple(Items)},
               {6, random_term_split(Items)}]).

random_term_split(Items) ->
    ?LET(N, choose(0, length(Items)),
         begin
             {Front, Rear} = lists:split(N, Items),
             oneof([{random_term(Front), random_term(Rear)},
                    [random_term(Front), random_term(Rear)],
                    [random_term(Front) | random_term(Rear)]])
         end).

safe_idiv(X) ->
    case X =/= 0 of
        true ->
            functools:idiv(X);
        false ->
            fun functools:id/1
    end.

random_fun_spec() ->
    list(oneof([fun functools:id/1] ++
                   [random_simple_fun_spec(BF) ||
                       BF <- [fun functools:const/1,
                              fun functools:add/1,
                              fun functools:sub/1,
                              fun functools:mul/1,
                              fun safe_idiv/1]])).

random_simple_fun_spec(BaseFun) ->
    ?LET(N, int(), {BaseFun, [N]}).

fun_spec_to_fun(Spec) ->
    fun (X) ->
            Funs = [case F of
                        _ when is_function(F) ->
                            F;
                        {BaseF, Args} ->
                            erlang:apply(BaseF, Args)
                    end || F <- Spec],
            functools:chain(X, Funs)
    end.

%% triq properties
prop_transform_id(Transform) ->
    ?FORALL(Term, any(), Transform(fun functools:id/1, Term) =:= Term).

prop_transformt_id() ->
    prop_transform_id(fun transformt/2).

prop_transformb_id() ->
    prop_transform_id(fun transformb/2).

%% traversal order is left to right, so the order of original elements must be
%% the same as in Items list
prop_transform_items_order(Transform) ->
    forall_terms(fun (Items, Term) ->
                         Items =:= matching(fun is_integer/1, Term, Transform)
                 end).

prop_transformt_items_order() ->
    prop_transform_items_order(fun transformt/3).

prop_transformb_items_order() ->
    prop_transform_items_order(fun transformb/3).

prop_transforms_same_subterms() ->
    forall_terms(fun (_Items, Term) ->
                         AllT = universe(Term, fun transformt/3),
                         AllB = universe(Term, fun transformb/3),
                         lists:sort(AllT) =:= lists:sort(AllB)
                 end).

prop_transforms_result(Transform) ->
    Props = ?FORALL(Spec, random_fun_spec(),
                    forall_terms(
                      fun (Items, Term) ->
                              Fun = fun_spec_to_fun(Spec),
                              TransFun = ?transform(I when is_integer(I), Fun(I)),

                              Items1 = lists:map(Fun, Items),
                              Term1  = Transform(TransFun, Term),

                              Items1 =:= matching(fun is_integer/1, Term1)
                      end)),

    %% each forall multiplies number of tests by 100 (by default), so we'd
    %% have to run 10^6 number of tests which is a bit too much; here we lower
    %% it to 22^3 (yes, it's somewhat confusing) which is approximately 10000
    triq:numtests(22, Props).

prop_transformt_result() ->
    prop_transforms_result(fun transformt/2).

prop_transformb_result() ->
    prop_transforms_result(fun transformb/2).

prop_query_result(QueryK, QueryFun, ListFun) ->
    forall_terms(fun (Items, Term) ->
                         ListFun(Items) =:= query(QueryK, QueryFun, Term)
                 end).

prop_query_count() ->
    prop_query_result(fun functools:add/2, ?query(I when is_integer(I), 1, 0),
                      fun erlang:length/1).

prop_query_sum() ->
    prop_query_result(fun functools:add/2, ?query(I when is_integer(I), I, 0),
                      fun lists:sum/1).

forall_terms(Prop) ->
    ?FORALL(Items, list(int()),
            ?FORALL(Term, random_term(Items), Prop(Items, Term))).
