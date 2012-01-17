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
-module(ns_moxi_sup).

-behaviour(supervisor).

-include("ns_common.hrl").

-export([start_link/0, rest_creds/0, rest_user/0, rest_pass/0]).

-export([init/1]).

%%
%% API
%%

rest_creds() ->
    case ns_config:search_prop(ns_config:get(), rest_creds, creds, []) of
        [] ->
            {"", ""};
        [{User, Creds}|_] ->
            {User, proplists:get_value(password, Creds, "")}
    end.


rest_pass() ->
    {_, Pass} = rest_creds(),
    Pass.


rest_user() ->
    {User, _} = rest_creds(),
    User.



start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%%
%% Supervisor callbacks
%%

init([]) ->
    ns_pubsub:subscribe_link(ns_config_events, fun notify/2, undefined),
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          child_specs()}}.


%%
%% Internal functions
%%

child_specs() ->
    Config = ns_config:get(),
    BucketConfigs = ns_bucket:get_buckets(Config),
    RestPort = ns_config:search_node_prop(Config, rest, port),
    Command = path_config:component_path(bin, "moxi"),
    lists:foldl(
      fun ({"default", _}, Acc) ->
              Acc;
          ({BucketName, BucketConfig}, Acc) ->
              case proplists:get_value(moxi_port, BucketConfig) of
                  undefined ->
                      Acc;
                  Port ->
                      LittleZ =
                          lists:flatten(
                            io_lib:format(
                              "url=http://127.0.0.1:~B/pools/default/"
                              "bucketsStreaming/~s",
                              [RestPort, BucketName])),
                      BigZ =
                          lists:flatten(
                            io_lib:format(
                              "port_listen=~B,downstream_max=1024,downstream_conn_max=4,"
                              "connect_max_errors=5,connect_retry_interval=30000,"
                              "connect_timeout=400,"
                              "auth_timeout=100,cycle=200,"
                              "downstream_conn_queue_timeout=200,"
                              "downstream_timeout=5000,wait_queue_timeout=200",
                              [Port])),
                      Args = ["-B", "auto", "-z", LittleZ, "-Z", BigZ,
                              "-p", "0", "-Y", "y", "-O", "stderr"],
                      Passwd = proplists:get_value(sasl_password, BucketConfig,
                                                   ""),
                      Opts = [use_stdio, stderr_to_stdout,
                              {env, [{"MOXI_SASL_PLAIN_USR", BucketName},
                                     {"MOXI_SASL_PLAIN_PWD", Passwd}]}],
                      [{{BucketName, Passwd, Port, RestPort},
                       {ns_port_server, start_link,
                        [moxi, Command, Args, Opts]},
                       permanent, 1000, worker, [ns_port_server]}|Acc]
              end
      end, [], BucketConfigs).

%% we depend on rest port
is_interesting_config_event({rest, _}) -> true;
is_interesting_config_event({{node, _, rest}, _}) -> true;
%% we depend on buckets config
is_interesting_config_event({buckets, _}) -> true;
%% and nothing else
is_interesting_config_event(_) -> false.


%% @doc Notify this supervisor of changes to the config that might be
%% relevant to it.
notify(Event, _) ->
    case is_interesting_config_event(Event) of
        true ->
            work_queue:submit_work(ns_moxi_sup_work_queue, fun do_notify/0);
        _ ->
            ok
    end.

do_notify() ->
    ChildSpecs = child_specs(),
    RunningChildren = supervisor:which_children(?MODULE),
    lists:foreach(fun ({Id, _, _, _}) ->
                          case lists:keymember(Id, 1, ChildSpecs) of
                              false ->
                                  ?log_info("Killing unwanted moxi: ~p", [Id]),
                                  supervisor:terminate_child(?MODULE, Id),
                                  ok = supervisor:delete_child(?MODULE, Id);
                              true ->
                                  ok
                          end
                  end, RunningChildren),
    lists:foreach(fun ({Id, _, _, _, _, _} = Child) ->
                          case lists:keymember(Id, 1, RunningChildren) of
                              false ->
                                  ?log_info("Starting moxi: ~p", [Id]),
                                  supervisor:start_child(?MODULE, Child);
                              true ->
                                  ok
                          end
                  end, ChildSpecs).
