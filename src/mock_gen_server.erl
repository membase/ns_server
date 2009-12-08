% Copyright (c) 2009, NorthScale, Inc
% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
%
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% * Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
% * Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
% * Neither the name of Powerset, Inc nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
% COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(mock_gen_server).

-behaviour(gen_server).

-include_lib("eunit/include/eunit.hrl").

%% API
-export([start_link/1, stub_call/3, expects_call/3, expects_call/4, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {call_stubs=[], call_expects=[],
                cast_expectations,
                info_expectations}).

%% API

start_link(Reference) ->
  gen_server:start_link(Reference, ?MODULE, [], []).

stub_call(Server, Sym, Fun) when is_function(Fun) ->
  gen_server:call(Server, {mock_stub_call, Sym, Fun}).

expects_call(Server, Args, Fun) when is_function(Fun) ->
  gen_server:call(Server, {mock_expects_call, Args, Fun}).

expects_call(Server, Args, Fun, Times) when is_function(Fun) ->
  gen_server:call(Server, {mock_expects_call, Args, Fun, Times}).

stop(Server) ->
  gen_server:call(Server, mock_stop).

%% gen_server callbacks

init([]) -> {ok, #state{}}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
handle_info(_Info, State) -> {noreply, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_call({mock_stub_call, Sym, Fun}, _From,
            State = #state{call_stubs=Stubs}) ->
  {reply, ok, State#state{call_stubs=[{Sym, Fun}|Stubs]}};

handle_call({mock_expects_call, Args, Fun}, _From,
            State = #state{call_expects=Expects}) ->
  {reply, ok, State#state{call_expects=add_expectation(Args, Fun,
                                                       at_least_once,
                                                       Expects)}};

handle_call({mock_expects_call, Args, Fun, Times}, _From,
            State = #state{call_expects=Expects}) ->
  {reply, ok, State#state{call_expects=add_expectation(Args, Fun, Times,
                                                       Expects)}};

handle_call(mock_stop, _From, State) ->
  {stop, shutdown, ok, State};

handle_call(Request, _From,
            State = #state{call_stubs=Stubs,call_expects=Expects}) ->
  % expectations have a higher priority
  case find_expectation(Request, Expects) of
    {found, {_, Fun, Time}, NewExpects} ->
      {reply, Fun(Request, Time), State#state{call_expects=NewExpects}};
    not_found -> % look for a stub
      case find_stub(Request, Stubs) of
        {found, {_, Fun}} -> {reply, Fun(Request), State};
        not_found ->
          {stop, {unexpected_call, Request}, State}
      end
  end.

%--------------------------------------------------------------------

add_expectation(Args, Fun, Times, Expects) ->
  Expects ++ [{Args, Fun, Times}].

find_expectation(Request, Expects) ->
  find_expectation(Request, Expects, []).

find_expectation(_Request, [], _Rest) ->
  not_found;

find_expectation(Request, [{Args, Fun, Times}|Expects], Rest) ->
  MatchFun = generate_match_fun(Args),
  case MatchFun(Request) of
    true ->
      if
        Times == at_least_once ->
              {found, {Args, Fun, Times},
               lists:reverse(Rest) ++ [{Args, Fun, Times}] ++ Expects};
        Times == 1 ->
              {found, {Args, Fun, Times},
               lists:reverse(Rest) ++ Expects};
        true ->
              {found, {Args, Fun, Times},
               lists:reverse(Rest) ++ [{Args, Fun, Times-1}] ++ Expects}
      end;
    false -> find_expectation(Request, Expects, [{Args, Fun, Times}|Rest])
  end.

find_stub(Request, Stub) when is_tuple(Request) ->
  Sym = element(1, Request),
  find_stub(Sym, Stub);

find_stub(_Sym, []) ->
  not_found;

find_stub(Sym, _Stubs) when not is_atom(Sym) ->
  not_found;

find_stub(Sym, [{Sym, Fun}|_Stubs]) ->
  {found, {Sym, Fun}};

find_stub(Sym, [_Stub|Stubs]) ->
  find_stub(Sym, Stubs).

generate_match_fun(Args) when is_tuple(Args) ->
  generate_match_fun(tuple_to_list(Args));

generate_match_fun(Args) when not is_list(Args) ->
  generate_match_fun([Args]);

generate_match_fun(Args) when is_list(Args) ->
  Src = generate_match_fun("fun({", Args),
  {ok, Tokens, _} = erl_scan:string(Src),
  {ok, [Form]} = erl_parse:parse_exprs(Tokens),
  {value, Fun, _} = erl_eval:expr(Form, erl_eval:new_bindings()),
  Fun.

generate_match_fun(Src, []) ->
  Src ++ "}) -> true; (_) -> false end.";

% unbound atom means you don't care about an arg
generate_match_fun(Src, [unbound|Args]) ->
  if
    length(Args) > 0 -> generate_match_fun(Src ++ "_,", Args);
    true -> generate_match_fun(Src ++ "_", Args)
  end;

generate_match_fun(Src, [Bound|Args]) ->
  Term = lists:flatten(io_lib:format("~w", [Bound])),
  if
    length(Args) > 0 -> generate_match_fun(Src ++ Term ++ ",", Args);
    true -> generate_match_fun(Src ++ Term, Args)
  end.
