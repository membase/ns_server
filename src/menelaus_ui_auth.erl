%% @author Couchbase <info@couchbase.com>
%% @copyright 2013 Couchbase, Inc.
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
-module(menelaus_ui_auth).

-include("ns_common.hrl").

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([generate_token/1, maybe_refresh/1,
         check/1, reset/0, logout/1]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

generate_token(Memo) ->
    gen_server:call(?MODULE, {generate_token, Memo}, infinity).

maybe_refresh(Token) ->
    gen_server:call(?MODULE, {maybe_refresh, tok2bin(Token)}, infinity).

tok2bin(Token) when is_list(Token) ->
    list_to_binary(Token);
tok2bin(Token) ->
    Token.

check(Token) ->
    gen_server:call(?MODULE, {check, tok2bin(Token)}, infinity).

reset() ->
    gen_server:call(?MODULE, reset, infinity).

logout(Token) ->
    gen_server:call(?MODULE, {logout, tok2bin(Token)}, infinity).

-define(MAX_TOKENS, 1024).

init([]) ->
    _ = ets:new(ui_auth_by_token, [private, named_table, set]),
    _ = ets:new(ui_auth_by_expiration, [private, named_table, ordered_set]),
    {ok, []}.

maybe_expire() ->
    Size = ets:info(ui_auth_by_token, size),
    case Size < ?MAX_TOKENS of
        true ->
            ok;
        _ ->
            expire_oldest()
    end.

expire_oldest() ->
    {Expiration, Token} = ets:first(ui_auth_by_expiration),
    ets:delete(ui_auth_by_expiration, {Expiration, Token}),
    ets:delete(ui_auth_by_token, Token).

delete_token(Token) ->
    case ets:lookup(ui_auth_by_token, Token) of
        [{Token, Expiration, ReplacedToken, _}] ->
            ets:delete(ui_auth_by_expiration, {Expiration, Token}),
            ets:delete(ui_auth_by_token, Token),
            ReplacedToken;
        [] ->
            false
    end.

get_now() ->
    misc:time_to_epoch_int(os:timestamp()).

do_generate_token(ReplacedToken, Memo) ->
    %% NOTE: couch_uuids:random is using crypto-strong random
    %% generator
    Token = couch_uuids:random(),
    Expiration = get_now() + ?UI_AUTH_EXPIRATION_SECONDS,
    ets:insert(ui_auth_by_token, {Token, Expiration, ReplacedToken, Memo}),
    ets:insert(ui_auth_by_expiration, {{Expiration, Token}}),
    Token.

validate_token_maybe_expire(Token) ->
    case ets:lookup(ui_auth_by_token, Token) of
        [{Token, Expiration, _, Memo}] ->
            Now = get_now(),
            case Expiration < Now of
                true ->
                    delete_token(Token),
                    false;
                _ ->
                    {Expiration, Now, Memo}
            end;
        [] ->
            false
    end.

handle_call(reset, _From, State) ->
    ets:delete_all_objects(ui_auth_by_token),
    ets:delete_all_objects(ui_auth_by_expiration),
    {reply, ok, State};
handle_call({generate_token, Memo}, _From, State) ->
    maybe_expire(),
    Token = do_generate_token(undefined, Memo),
    {reply, Token, State};
handle_call({maybe_refresh, Token}, _From, State) ->
    case validate_token_maybe_expire(Token) of
        false ->
            {reply, nothing, State};
        {Expiration, Now, Memo} ->
            case Expiration - Now < ?UI_AUTH_EXPIRATION_SECONDS / 2 of
                true ->
                    %% NOTE: we take note of current and still valid
                    %% token for correctness of logout
                    %%
                    %% NOTE: condition above ensures that there are at
                    %% most 2 valid tokens per session
                    NewToken = do_generate_token(Token, Memo),
                    {reply, {new_token, NewToken}, State};
                false ->
                    {reply, nothing, State}
            end
    end;
handle_call({logout, Token}, _From, State) ->
    %% NOTE: {maybe_refresh... above is inserting new token when old is
    %% still valid (to give current requests time to finish). But
    %% gladly we also store older and potentially valid token, so we
    %% can delete it as well here
    OlderButMaybeValidToken = delete_token(Token),
    case OlderButMaybeValidToken of
        undefined ->
            ok;
        false ->
            ok;
        _ ->
            delete_token(OlderButMaybeValidToken)
    end,
    {reply, ok, State};
handle_call({check, Token}, _From, State) ->
    case validate_token_maybe_expire(Token) of
        false ->
            {reply, false, State};
        {_, _, Memo} ->
            {reply, {ok, Memo}, State}
    end;
handle_call(Msg, From, _State) ->
    erlang:error({unknown_call, Msg, From}).

handle_cast(Msg, _State) ->
    erlang:error({unknown_cast, Msg}).

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
