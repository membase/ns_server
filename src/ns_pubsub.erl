%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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

-module(ns_pubsub).

-behaviour(gen_event).

-record(state, {func, func_state}).

-export([code_change/3, init/1, handle_call/2, handle_event/2, handle_info/2,
         terminate/2]).

-export([subscribe/1, subscribe/3, unsubscribe/2]).


%%
%% API
%%
subscribe(Name) ->
    subscribe(Name, msg_fun(self()), ignored).


subscribe(Name, Fun, State) ->
    Ref = make_ref(),
    ok = gen_event:add_sup_handler(Name, {?MODULE, Ref},
                                   #state{func=Fun, func_state=State}),
    Ref.

unsubscribe(Name, Ref) ->
    gen_event:delete_handler(Name, {?MODULE, Ref}, unsubscribed).

%%
%% gen_event callbacks
%%
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


init(State) ->
    {ok, State}.


handle_call(_Request, State) ->
    {reply, ok, State}.


handle_event(Event, State = #state{func=Fun, func_state=FS}) ->
    NewState = Fun(Event, FS),
    {ok, State#state{func_state=NewState}}.


handle_info(_Msg, State) ->
    {ok, State}.


terminate(_Reason, _State) ->
    ok.


%%
%% Internal functions
%%

%% Function sending a message to a pid
msg_fun(Pid) ->
    fun (Event, ignored) ->
            Pid ! Event,
            ignored
    end.
