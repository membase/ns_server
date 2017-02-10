%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
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

-module(menelaus_cbauth).

-export([handle_cbauth_post/1]).
-behaviour(gen_server).

-export([start_link/0]).


-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {cbauth_info = undefined, rpc_processes = []}).

-include("ns_common.hrl").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ns_pubsub:subscribe_link(json_rpc_events, fun json_rpc_event/1),
    ns_pubsub:subscribe_link(ns_node_disco_events, fun node_disco_event/1),
    ns_pubsub:subscribe_link(ns_config_events, fun ns_config_event/1),
    ns_pubsub:subscribe_link(user_storage_events, fun user_storage_event/1),
    json_rpc_connection_sup:reannounce(),
    {ok, #state{}}.

json_rpc_event({_, Label, _} = Event) ->
    case is_cbauth_connection(Label) of
        true ->
            ok = gen_server:cast(?MODULE, Event);
        false ->
            ok
    end.

node_disco_event(_Event) ->
    ?MODULE ! maybe_notify_cbauth.

ns_config_event(Event) ->
    case is_interesting(Event) of
        true ->
            ?MODULE ! maybe_notify_cbauth;
        _ ->
            ok
    end.

user_storage_event(_Event) ->
    ?MODULE ! maybe_notify_cbauth.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

is_interesting({{node, _, services}, _}) -> true;
is_interesting({{service_map, _}, _}) -> true;
is_interesting({{node, _, membership}, _}) -> true;
is_interesting({{node, _, memcached}, _}) -> true;
is_interesting({{node, _, capi_port}, _}) -> true;
is_interesting({{node, _, ssl_capi_port}, _}) -> true;
is_interesting({{node, _, ssl_rest_port}, _}) -> true;
is_interesting({rest, _}) -> true;
is_interesting({rest_creds, _}) -> true;
is_interesting({cluster_compat_version, _}) -> true;
is_interesting({{node, _, is_enterprise}, _}) -> true;
is_interesting({roles_definitions, _}) -> true;
is_interesting({user_roles, _}) -> true;
is_interesting(_) -> false.

handle_call(_Msg, _From, State) ->
    {reply, not_implemented, State}.

handle_cast({Msg, Label, Pid}, #state{rpc_processes = Processes,
                                      cbauth_info = CBAuthInfo} = State) ->
    ?log_debug("Observed json rpc process ~p ~p", [{Label, Pid}, Msg]),
    Info = case CBAuthInfo of
               undefined ->
                   build_auth_info();
               _ ->
                   CBAuthInfo
           end,
    NewProcesses = case notify_cbauth(Label, Pid, Info) of
                       error ->
                           Processes;
                       ok ->
                           case lists:keyfind({Label, Pid}, 2, Processes) of
                               false ->
                                   MRef = erlang:monitor(process, Pid),
                                   [{MRef, {Label, Pid}} | Processes];
                               _ ->
                                   Processes
                           end
                   end,
    {noreply, State#state{rpc_processes = NewProcesses,
                          cbauth_info = Info}}.

handle_info(maybe_notify_cbauth, State) ->
    misc:flush(maybe_notify_cbauth),
    {noreply, maybe_notify_cbauth(State)};
handle_info({'DOWN', MRef, _, Pid, Reason},
            #state{rpc_processes = Processes} = State) ->
    {value, {MRef, {Label, Pid}}, NewProcesses} = lists:keytake(MRef, 1, Processes),
    ?log_debug("Observed json rpc process ~p died with reason ~p", [{Label, Pid}, Reason]),
    {noreply, State#state{rpc_processes = NewProcesses}};

handle_info(_Info, State) ->
    {noreply, State}.

maybe_notify_cbauth(#state{rpc_processes = Processes,
                           cbauth_info = CBAuthInfo} = State) ->
    case build_auth_info() of
        CBAuthInfo ->
            State;
        Info ->
            [notify_cbauth(Label, Pid, Info) || {_, {Label, Pid}} <- Processes],
            State#state{cbauth_info = Info}
    end.

notify_cbauth(Label, Pid, Info) ->
    Method = "AuthCacheSvc.UpdateDB",
    SpecialUser = ns_config_auth:get_user(special) ++ Label,
    NewInfo = {[{specialUser, erlang:list_to_binary(SpecialUser)} | Info]},

    try json_rpc_connection:perform_call(Label, Method, NewInfo) of
        {error, method_not_found} ->
            error;
        {error, {rpc_error, _}} ->
            error;
        {error, Error} ->
            ?log_error("Error returned from go component ~p: ~p. This shouldn't happen but crash it just in case.",
                       [{Label, Pid}, Error]),
            exit(Pid, Error),
            error;
        {ok, true} ->
            ok
    catch exit:{noproc, _} ->
            ?log_debug("Process ~p is already dead", [{Label, Pid}]),
            error;
          exit:{Reason, _} ->
            ?log_debug("Process ~p has exited during the call with reason ~p",
                       [{Label, Pid}, Reason]),
            error
    end.

build_node_info(N, Config) ->
    build_node_info(N, ns_config:search_node_prop(N, Config, memcached, admin_user), Config).

build_node_info(_N, undefined, _Config) ->
    undefined;
build_node_info(N, User, Config) ->
    Services = bucket_info_cache:build_services(
                 N, Config,
                 ns_cluster_membership:node_active_services(Config, N)),

    {_, Host} = misc:node_name_host(N),
    Local = case node() of
                N ->
                    [{local, true}];
                _ ->
                    []
            end,
    {[{host, erlang:list_to_binary(Host)},
      {user, erlang:list_to_binary(User)},
      {password,
       erlang:list_to_binary(ns_config:search_node_prop(N, Config, memcached, admin_pass))},
      {ports, [Port || {_Key, Port} <- Services]}] ++ Local}.

build_auth_info() ->
    Config = ns_config:get(),
    Nodes = lists:foldl(fun (Node, Acc) ->
                                case build_node_info(Node, Config) of
                                    undefined ->
                                        Acc;
                                    Info ->
                                        [Info | Acc]
                                end
                        end, [], ns_node_disco:nodes_wanted(Config)),

    Port = misc:node_rest_port(Config, node()),
    AuthCheckURL = io_lib:format("http://127.0.0.1:~w/_cbauth", [Port]),
    PermissionCheckURL = io_lib:format("http://127.0.0.1:~w/_cbauth/checkPermission", [Port]),

    [{nodes, Nodes},
     {authCheckURL, iolist_to_binary(AuthCheckURL)},
     {permissionCheckURL, iolist_to_binary(PermissionCheckURL)},
     {permissionsVersion, menelaus_web_rbac:check_permissions_url_version(Config)},
     {authVersion, auth_version(Config)}].

auth_version(Config) ->
    erlang:phash2([ns_config_auth:get_creds(Config, admin),
                   menelaus_users:get_auth_version()]).

handle_cbauth_post(Req) ->
    {User, Source} = menelaus_auth:get_identity(Req),
    menelaus_util:reply_json(Req, {[{user, erlang:list_to_binary(User)},
                                    {source, Source}]}).

is_cbauth_connection(Label) ->
    lists:suffix("-cbauth", Label).
