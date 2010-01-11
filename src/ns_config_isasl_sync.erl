% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_config_isasl_sync).

-behaviour(gen_event).

-export([start_link/0, start_link/1, setup_handler/1]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

% Useful for testing.
-export([extract_creds/1]).

-record(state, {buckets, path, updates}).

start_link() ->
    {value, Path} = ns_config:search(ns_config:get(), isasl_path),
    start_link(Path).

start_link(Path) ->
    {ok, spawn_link(?MODULE, setup_handler, [Path])}.

setup_handler(Path) ->
    gen_event:add_handler(ns_config_events, ?MODULE, Path).

init(Path) ->
    {value, Pools} = ns_config:search(ns_config:get(), pools),
    Buckets = extract_creds(Pools),
    writeSASLConf(Path, Buckets),
    {ok, #state{buckets=Buckets, path=Path, updates=0}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_event({pools, V}, State) ->
    Prev = State#state.buckets,
    case extract_creds(V) of
        Prev ->
            {ok, State, hibernate};
        NewBuckets ->
            writeSASLConf(State#state.path, NewBuckets),
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

writeSASLConf(Path, NewBuckets) ->
    error_logger:info_msg("Writing isasl passwd file~n", []),
    {ok, F} = file:open(Path, [write]),
    lists:foreach(fun ({U, P}) -> io:format(F, "~s ~s~n", [U, P]) end,
                  NewBuckets),
    file:close(F).
