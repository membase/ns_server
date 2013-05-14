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
%%
-module(ns_config_isasl_sync).

-behaviour(gen_server).

-export([start_link/0, start_link/3, writeSASLConf/6, sync/0]).

%% gen_event callbacks
-export([init/1, handle_cast/2, handle_call/3,
         handle_info/2, terminate/2, code_change/3]).

% Useful for testing.
-export([extract_creds/1]).

-include("ns_common.hrl").

-record(state, {buckets,
                path,
                updates,
                admin_user,
                admin_pass,
                write_pending}).

sync() ->
    ns_config:sync_announcements(),
    gen_server:call(?MODULE, sync, infinity).

start_link() ->
    Config = ns_config:get(),
    Path = ns_config:search_node_prop(Config, isasl, path),
    AU = ns_config:search_node_prop(Config, memcached, admin_user),
    AP = ns_config:search_node_prop(Config, memcached, admin_pass),
    start_link(Path, AU, AP).

start_link(Path, AU, AP) when is_list(Path); is_list(AU); is_list(AP) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [Path, AU, AP], []).

init([Path, AU, AP] = Args) ->
    ?log_debug("isasl_sync init: ~p", [Args]),
    Buckets =
        case ns_config:search(buckets) of
            {value, RawBuckets} ->
                extract_creds(RawBuckets);
            _ -> []
        end,
    %% don't log passwords here
    ?log_debug("isasl_sync init buckets: ~p", [proplists:get_keys(Buckets)]),
    Pid = self(),
    ns_pubsub:subscribe_link(ns_config_events,
                             fun ({buckets, _V}=Evt, _) ->
                                     gen_server:cast(Pid, Evt);
                                 (_, _) -> ok
                             end, ignored),
    writeSASLConf(Path, Buckets, AU, AP),
    {ok, #state{buckets=Buckets, path=Path, updates=0,
                admin_user=AU, admin_pass=AP}}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

handle_cast({buckets, V}, State) ->
    Prev = State#state.buckets,
    case extract_creds(V) of
        Prev ->
            {noreply, State};
        NewBuckets ->
            {noreply, initiate_write(State#state{buckets=NewBuckets})}
    end;
handle_cast(write_sasl_conf, State) ->
    writeSASLConf(State#state.path, State#state.buckets,
                  State#state.admin_user, State#state.admin_pass),
    {noreply, State#state{updates = State#state.updates + 1,
                          write_pending = false}};
handle_cast(Msg, State) ->
    ?log_error("Unknown cast: ~p", [Msg]),
    {noreply, State}.

handle_call(sync, _From, State) ->
    {reply, ok, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%% this sends us cast that performs actual sasl writing. The end
%% effect is batching of {buckets, _} cast processing. So that we
%% don't write file after every "buckets" config key change.
initiate_write(#state{write_pending = true} = State) ->
    State;
initiate_write(State) ->
    gen_server:cast(?MODULE, write_sasl_conf),
    State#state{write_pending = true}.

%
% Extract the credentials from the config to a list of tuples of {User, Pass}
%

-spec extract_creds(list()) -> [{_,_}].
extract_creds(ConfigList) ->
    Configs = proplists:get_value(configs, ConfigList),
    lists:sort([{BucketName,
                 proplists:get_value(sasl_password, BucketConfig, "")}
                || {BucketName, BucketConfig} <- Configs]).


%%
%% sasl the isasl stuff.
%%

writeSASLConf(Path, Buckets, AU, AP) ->
    writeSASLConf(Path, Buckets, AU, AP, 5, 101).

-spec writeSASLConf(nonempty_string(), list(), string(), string(),
                     non_neg_integer(), non_neg_integer()) ->
    any().
writeSASLConf(Path, Buckets, AU, AP, Tries, SleepTime) ->
    {ok, Pwd} = file:get_cwd(),
    TmpPath = filename:join(filename:dirname(Path), "isasl.tmp"),
    ok = filelib:ensure_dir(TmpPath),
    ?log_debug("Writing isasl passwd file: ~p", [filename:join(Pwd, Path)]),
    {ok, F} = file:open(TmpPath, [write]),
    io:format(F, "~s ~s~n", [AU, AP]),
    lists:foreach(
      fun({User, Pass}) ->
              io:format(F, "~s ~s~n", [User, Pass])
      end,
      Buckets),
    file:close(F),
    case file:rename(TmpPath, Path) of
        ok ->
            case (catch ns_memcached:connect_and_send_isasl_refresh()) of
                ok -> ok;
                %% in case memcached is not yet started
                {error, couldnt_connect_to_memcached} -> ok;
                Error ->
                    ?log_error("Failed to force update of memcached isasl configuration:~p", [Error])
            end;
        {error, Reason} ->
            ?log_warning("Error renaming ~p to ~p: ~p", [TmpPath, Path, Reason]),
            case Tries of
                0 -> {error, Reason};
                _ ->
                    ?log_info("Trying again after ~p ms (~p tries remaining)",
                              [SleepTime, Tries]),
                    {ok, _TRef} = timer2:apply_after(SleepTime, ?MODULE, writeSASLConf, [Path, Buckets, AU, AP, Tries - 1, SleepTime * 2.0])
            end
    end.
