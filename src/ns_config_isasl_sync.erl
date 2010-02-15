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

init([Path, AU, AP] = Args) ->
    error_logger:info_msg("isasl_sync init: ~p~n", [Args]),
    {value, Pools} = ns_config:search(ns_config:get(), pools),
    Buckets = extract_creds(Pools),
    error_logger:info_msg("isasl_sync init buckets: ~p~n", [Buckets]),
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
extract_creds(PoolConfigList) ->
    lists:sort(
      dict:to_list(
        lists:foldl(fun examine_pool/2, dict:new(), PoolConfigList))).

examine_pool({_PoolName, PoolProps}, D) ->
    lists:foldl(fun examine_bucket/2, D,
                proplists:get_value(buckets, PoolProps, [])).


examine_bucket({BucketName, BucketProps}, D) ->
    case proplists:get_value(auth_plain, BucketProps) of
        undefined -> D;
        {BucketName, ""} ->
            error_logger:info_msg("Rejecting user with empty password: ~p: ~p~n",
                                  [BucketName, BucketProps]),
            D;
        {BucketName, _Passwd} ->
            dict:store(BucketName, BucketProps, D)
    end.

%
% Update the isasl stuff.
%

writeSASLConf(Path, Buckets, AU, AP) ->
    writeSASLConf(Path, Buckets, AU, AP, 5, 101).

writeSASLConf(Path, Buckets, AU, AP, Tries, SleepTime) ->
    {ok, Pwd} = file:get_cwd(),
    PrivDir = filename:join(Pwd, "priv"),
    FullPath = filename:join(PrivDir, Path),
    FullTmpPath = filename:join(PrivDir, "isasl.tmp"),
    error_logger:info_msg("Writing isasl passwd file: ~p~n", [FullPath]),
    {ok, F} = file:open(FullTmpPath, [write]),
    io:format(F, "~s ~s~n", [AU, AP]),
    lists:foreach(
      fun({_BucketName, BucketProps}) ->
              SizePerNode = proplists:get_value(size_per_node, BucketProps, 64),
              Config = "cache_size=" ++ integer_to_list(SizePerNode),
              {User, Pass} = proplists:get_value(auth_plain, BucketProps),
              io:format(F, "~s ~s ~s~n", [User, Pass, Config])
      end,
      Buckets),
    file:close(F),
    case file:rename(FullTmpPath, FullPath) of
        ok -> ok;
        {error, Reason} ->
            error_logger:info_msg("Error renaming ~p to ~p: ~p~n", [FullTmpPath, FullPath, Reason]),
            case Tries of
                0 -> {error, Reason};
                _ ->
                    error_logger:info_msg("Trying again after ~p ms (~p tries remaining)~n", [SleepTime, Tries]),
                    {ok, _TRef} = timer:apply_after(SleepTime, ?MODULE, writeSASLConf, [Path, Buckets, AU, AP, Tries - 1, SleepTime * 2.0])
            end
    end.
