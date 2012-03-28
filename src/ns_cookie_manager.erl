%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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
%% @doc Process managing cookies. Split from ns_node_disco to avoid race
%% conditions while saving cookies to disk.
-module(ns_cookie_manager).

-behavior(gen_server).

-include("ns_common.hrl").

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
-export([start_link/0,
         cookie_init/0, cookie_gen/0,
         cookie_get/0, cookie_set/1, cookie_sync/0]).

-export([ns_log_cat/1, ns_log_code_string/1]).


-define(SERVER, ?MODULE).
-record(state, {}).

-define(COOKIE_INHERITED, 1).
-define(COOKIE_SYNCHRONIZED, 2).
-define(COOKIE_GEN, 3).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

cookie_init() ->
    gen_server:call(?SERVER, cookie_init).

cookie_gen() ->
    gen_server:call(?SERVER, cookie_gen).

cookie_get() ->
    gen_server:call(?SERVER, cookie_get).

cookie_set(Cookie) ->
    gen_server:call(?SERVER, {cookie_set, Cookie}).

cookie_sync() ->
    gen_server:call(?SERVER, cookie_sync).

init([]) ->
    {ok, #state{}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _) ->
    {ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

handle_call(cookie_init, _From, State) ->
    {reply, do_cookie_init(), State};
handle_call(cookie_gen, _From, State) ->
    {reply, do_cookie_gen(), State};
handle_call(cookie_get, _From, State) ->
    {reply, do_cookie_get(), State};
handle_call({cookie_set, Cookie}, _From, State) ->
    {reply, do_cookie_set(Cookie), State};
handle_call(cookie_sync, _From, State) ->
    {reply, do_cookie_sync(), State}.

%% Auxiliary functions

do_cookie_init() ->
    NewCookie = do_cookie_gen(),
    ?user_log(?COOKIE_GEN, "Initial otp cookie generated: ~p",
              [NewCookie]),
    ok = do_cookie_set(NewCookie),
    {ok, NewCookie}.

do_cookie_gen() ->
    case misc:get_env_default(dont_reset_cookie, false) of
        false ->
            {A1, A2, A3} = erlang:now(),
            random:seed(A1, A2, A3),
            list_to_atom(misc:rand_str(16));
        true ->
            erlang:get_cookie()
    end.

do_cookie_get() ->
    ns_config:search_prop(ns_config:get(), otp, cookie).

do_cookie_set(Cookie) ->
    X = ns_config:set(otp, [{cookie, Cookie}]),
    erlang:set_cookie(node(), Cookie),
    X.

do_cookie_sync() ->
    ?log_debug("ns_cookie_manager do_cookie_sync"),
    Result =
        case do_cookie_get() of
            undefined ->
                case erlang:get_cookie() of
                    nocookie ->
                        % TODO: We should have length(nodes_wanted) == 0 or 1,
                        %       so, we should check that assumption.
                        do_cookie_init();
                    CurrCookie ->
                        ?user_log(?COOKIE_INHERITED,
                                  "Node ~p inherited otp cookie ~p from cluster",
                                  [node(), CurrCookie]),
                        do_cookie_set(CurrCookie),
                        {ok, CurrCookie}
                end;
            WantedCookie ->
                case erlang:get_cookie() of
                    WantedCookie -> {ok, WantedCookie};
                    _ ->
                        ?user_log(?COOKIE_SYNCHRONIZED,
                                  "Node ~p synchronized otp cookie ~p from cluster",
                                  [node(), WantedCookie]),
                        erlang:set_cookie(node(), WantedCookie),
                        {ok, WantedCookie}
                end
        end,

    case Result of
        {ok, Cookie} ->
            do_cookie_save(Cookie),
            Result
    end.

%% Saves cookie in human readable format.
-spec do_cookie_save(atom(), string()) -> ok | {error, term()}.
do_cookie_save(Cookie, Path) ->
    ?log_debug("saving cookie to ~p", [Path]),
    R = misc:atomic_write_file(Path, erlang:atom_to_list(Cookie) ++ "\n"),
    ?log_debug("attempted to save cookie to ~p: ~p", [Path, R]),
    R.

-spec do_cookie_save(atom()) -> ok | {error, term()}.
do_cookie_save(Cookie) ->
    case application:get_env(cookiefile) of
        {ok, CookieFile} -> do_cookie_save(Cookie, CookieFile);
        X -> X
    end.

ns_log_cat(_X) ->
    info.

ns_log_code_string(?COOKIE_INHERITED) ->
    "cookie update";
ns_log_code_string(?COOKIE_SYNCHRONIZED) ->
    "cookie update";
ns_log_code_string(?COOKIE_GEN) ->
    "cookie update".
