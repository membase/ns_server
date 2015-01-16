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
    json_rpc_connection:reannounce(),
    {ok, #state{}}.

json_rpc_event(Event) ->
    ok = gen_server:cast(?MODULE, Event).

node_disco_event(_Event) ->
    ?MODULE ! maybe_notify_cbauth.

ns_config_event(Event) ->
    case is_interesting(Event) of
        true ->
            ?MODULE ! maybe_notify_cbauth;
        _ ->
            ok
    end.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.

is_interesting({{node, _, services}, _}) -> true;
is_interesting({{node, _, membership}, _}) -> true;
is_interesting({{node, _, memcached}, _}) -> true;
is_interesting({{node, _, capi_port}, _}) -> true;
is_interesting({{node, _, ssl_capi_port}, _}) -> true;
is_interesting({{node, _, ssl_rest_port}, _}) -> true;
is_interesting({buckets, _}) -> true;
is_interesting({rest, _}) -> true;
is_interesting({rest_creds, _}) -> true;
is_interesting({read_only_user_creds, _}) -> true;
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
    NewProcesses = case notify_cbauth(Label, Info) of
                       {error, method_not_found} ->
                           Processes;
                       _ ->
                           case lists:keyfind(Label, 2, Processes) of
                               false ->
                                   MRef = erlang:monitor(process, Pid),
                                   [{MRef, Label} | Processes];
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
    {value, {MRef, Label}, NewProcesses} = lists:keytake(MRef, 1, Processes),
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
            [notify_cbauth(Label, Info) || {_, Label} <- Processes],
            State#state{cbauth_info = Info}
    end.

notify_cbauth(Label, Info) ->
    Method = "AuthCacheSvc.UpdateDB",
    try json_rpc_connection:perform_call(Label, Method, Info) of
        {error, <<"rpc: can't find method ", _/binary>>} ->
            ?log_debug("Rpc connection doesn't implement ~p", [Method]),
            {error, method_not_found};
        {error, Error} ->
            ?log_error("Error returned from go component ~p", [Error]),
            {error, Error};
        {ok, true} ->
            ok
    catch exit:{noproc, _} ->
            ?log_debug("Process for label ~p is already dead", [Label]),
            {error, noproc}
    end.

interesting_service(kv) ->
    true;
interesting_service(mgmt) ->
    true;
interesting_service(capi) ->
    true;
interesting_service(capiSSL) ->
    true;
interesting_service(mgmtSSL) ->
    true;
interesting_service(_) ->
    false.

build_node_info(N, Config) ->
    Services = bucket_info_cache:build_services(N, Config,
                                                ns_cluster_membership:node_services(Config, N)),
    {_, Host} = misc:node_name_host(N),
    Local = case node() of
                N ->
                    [{local, true}];
                _ ->
                    []
            end,
    {[{host, erlang:list_to_binary(Host)},
      {admin_user,
       erlang:list_to_binary(ns_config:search_node_prop(N, Config, memcached, admin_user))},
      {admin_pass,
       erlang:list_to_binary(ns_config:search_node_prop(N, Config, memcached, admin_pass))},
      {ports, [Port || {Key, Port} <- Services,
                       interesting_service(Key)]}] ++ Local}.

build_buckets_info() ->
    Buckets = ns_bucket:get_buckets(),
    {lists:map(fun ({BucketName, BucketProps}) ->
                       {erlang:list_to_binary(BucketName),
                        case proplists:get_value(auth_type, BucketProps) of
                            sasl ->
                                erlang:list_to_binary(proplists:get_value(sasl_password, BucketProps));
                            none ->
                                <<"">>
                        end}
               end, Buckets)}.

build_cred_info(Role) ->
    case ns_config_auth:get_creds(Role) of
        {User, Salt, Mac} ->
            [{Role, {[{user, erlang:list_to_binary(User)},
                      {salt, base64:encode(Salt)},
                      {mac, base64:encode(Mac)}]}}];
        undefined ->
            []
    end.

build_auth_info() ->
    Config = ns_config:get(),
    Nodes =
        [build_node_info(N, Config) || N <- ns_cluster_membership:active_nodes(Config)],

    TokenURL = io_lib:format("http://127.0.0.1:~w/_cbauth", [misc:node_rest_port(Config, node())]),

    {[{nodes, Nodes},
      {buckets, build_buckets_info()},
      {tokenCheckURL, iolist_to_binary(TokenURL)}
      | (build_cred_info(admin) ++ build_cred_info(ro_admin))]}.

handle_cbauth_post(Req) ->
    Role = menelaus_auth:get_role(Req),
    User = menelaus_auth:get_user(Req),
    menelaus_util:reply_json(Req, {[{role, erlang:list_to_binary(Role)},
                                    {user, erlang:list_to_binary(User)}]}).
