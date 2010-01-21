% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_config_isasl_sync).

-behaviour(gen_event).

-export([start_link/0, start_link/3, setup_handler/3]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

% Useful for testing.
-export([extract_creds/1]).

-record(state, {buckets, path, updates, admin_user, admin_pass}).

start_link() ->
    Config = ns_config:get(),
    Path = ns_config:search_prop(Config, isasl, path),
    AU = ns_config:search_prop(Config, bucket_admin, user),
    AP = ns_config:search_prop(Config, bucket_admin, pass),
    start_link(Path, AU, AP).

start_link(Path, AU, AP) when is_list(Path); is_list(AU); is_list(AP) ->
    {ok, spawn_link(?MODULE, setup_handler, [Path, AU, AP])}.

setup_handler(Path, AU, AP) ->
    gen_event:add_handler(ns_config_events, ?MODULE, [Path, AU, AP]).

init([Path, AU, AP]) ->
    {value, Pools} = ns_config:search(ns_config:get(), pools),
    Buckets = extract_creds(Pools),
    writeSASLConf(Path, Buckets, AU, AP),
    {ok, #state{buckets=Buckets, path=Path, updates=0,
                admin_user=AU, admin_pass=AP},
     hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({pools, V}, State) ->
    Prev = State#state.buckets,
    case extract_creds(V) of
        Prev ->
            {ok, State, hibernate};
        NewBuckets ->
            writeSASLConf(State#state.path, NewBuckets,
                         State#state.admin_user, State#state.admin_pass),
            {ok, State#state{buckets=NewBuckets,
                            updates=State#state.updates + 1}, hibernate}
    end;
handle_event(_, State) ->
    {ok, State, hibernate}.

handle_call(Request, State) ->
    error_logger:info_msg("handle_call(~p, ~p)~n", [Request, State]),
    {ok, ok, State, hibernate}.

handle_info(Info, State) ->
    error_logger:info_msg("handle_info(~p, ~p)~n", [Info, State]),
    {ok, State, hibernate}.

%
% Extract the credentials from the config to a list of tuples of {User, Pass}
%

-spec extract_creds(list()) -> list().
extract_creds(PropList) ->
    lists:sort(
      dict:to_list(
        lists:foldl(fun examine_pool/2, dict:new(), PropList))).

examine_pool({_Name, Props}, D) ->
    lists:foldl(fun examine_bucket/2, D,
                proplists:get_value(buckets, Props, [])).

examine_bucket({Name, Props}, D) ->
    case proplists:get_value(auth_plain, Props) of
        undefined ->
            D;
        Passwd ->
            dict:store(Name, Passwd, D)
    end.

%
% Update the isasl stuff.
%

writeSASLConf(Path, NewBuckets, AU, AP) ->
    error_logger:info_msg("Writing isasl passwd file~n", []),
    {ok, F} = file:open(Path, [write]),
    io:format(F, "~s ~s~n", [AU, AP]),
    lists:foreach(fun ({U, P}) -> io:format(F, "~s ~s~n", [U, P]) end,
                  NewBuckets),
    file:close(F).
