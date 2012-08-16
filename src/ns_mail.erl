%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_mail).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([send/5]).

-include("ns_common.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, empty_state}.

handle_call({send, Sender, Rcpts, Body, Options}, _From, State) ->
    Reply = gen_smtp_client:send_blocking({Sender, Rcpts, Body}, Options),
    case Reply of
        {error, _, Reason} ->
            ale:warn(?USER_LOGGER,
                     "Could not send email: ~p. "
                     "Make sure that your email settings are correct.", [Reason]);
        _ -> ok
    end,
    {reply, Reply, State};

handle_call(Request, From, State) ->
    ?log_warning("ns_mail: unexpected call ~p from ~p", [Request, From]),
    {ok, State}.

handle_cast(Request, State) ->
    ?log_warning("ns_mail: unexpected cast ~p.", [Request]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

send(Sender, Rcpts, Subject, Body, Options) ->
    Message = mimemail:encode({<<"text">>, <<"plain">>,
                              make_headers(Sender, Rcpts, Subject), [],
                              list_to_binary(Body)}),
    gen_server:call(?MODULE, {send, Sender, Rcpts, binary_to_list(Message),
                              Options}).

%% Internal functions

format_addr(Rcpts) ->
    string:join(["<" ++ Addr ++ ">" || Addr <- Rcpts], ", ").

make_headers(Sender, Rcpts, Subject) ->
    [{<<"From">>, list_to_binary(format_addr([Sender]))},
     {<<"To">>, list_to_binary(format_addr(Rcpts))},
     {<<"Subject">>, list_to_binary(Subject)}].
