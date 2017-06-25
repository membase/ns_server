%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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
%% @doc implementation of local and external users

-module(menelaus_users).

-include("ns_common.hrl").
-include("ns_config.hrl").
-include("rbac.hrl").
-include("pipes.hrl").

-include_lib("eunit/include/eunit.hrl").

-export([get_users_45/1,
         select_users/1,
         select_auth_infos/1,
         store_user/4,
         delete_user/1,
         change_password/2,
         authenticate/2,
         get_roles/1,
         user_exists/1,
         get_user_name/1,
         upgrade_to_4_5/1,
         get_salt_and_mac/1,
         build_memcached_auth/1,
         build_memcached_auth_info/1,
         build_plain_memcached_auth_info/2,
         get_users_version/0,
         get_auth_version/0,
         empty_storage/0,
         upgrade_to_spock/2,
         config_upgrade/0,
         upgrade_status/0,
         get_passwordless/0,
         filter_out_invalid_roles/3,
         cleanup_bucket_roles/1]).

%% callbacks for replicated_dets
-export([init/1, on_save/2, on_empty/1, handle_call/4, handle_info/2]).

-export([start_storage/0, start_replicator/0, start_auth_cache/0]).

%% RPC'd from ns_couchdb node
-export([get_auth_info_on_ns_server/1]).

-define(MAX_USERS_ON_CE, 20).

-record(state, {base, passwordless}).

replicator_name() ->
    users_replicator.

storage_name() ->
    users_storage.

versions_name() ->
    menelaus_users_versions.

auth_cache_name() ->
    menelaus_users_cache.

start_storage() ->
    Replicator = erlang:whereis(replicator_name()),
    Path = filename:join(path_config:component_path(data, "config"), "users.dets"),
    CacheSize = ns_config:read_key_fast(menelaus_users_cache_size, 256),
    replicated_dets:start_link(?MODULE, [], storage_name(), Path, Replicator, CacheSize).

get_users_version() ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            [{user_version, V, Base}] = ets:lookup(versions_name(), user_version),
            {V, Base};
        true ->
            rpc:call(ns_node_disco:ns_server_node(), ?MODULE, get_users_version, [])
    end.

get_auth_version() ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            [{auth_version, V, Base}] = ets:lookup(versions_name(), auth_version),
            {V, Base};
        true ->
            rpc:call(ns_node_disco:ns_server_node(), ?MODULE, get_auth_version, [])
    end.

start_replicator() ->
    GetRemoteNodes =
        fun () ->
                ns_node_disco:nodes_actual_other()
        end,
    doc_replicator:start_link(replicated_dets, replicator_name(), GetRemoteNodes, storage_name()).

start_auth_cache() ->
    versioned_cache:start_link(
      auth_cache_name(), 200,
      fun (I) ->
              ?log_debug("Retrieve user ~p from ns_server node", [I]),
              rpc:call(ns_node_disco:ns_server_node(), ?MODULE, get_auth_info_on_ns_server, [I])
      end,
      fun () ->
              dist_manager:wait_for_node(fun ns_node_disco:ns_server_node/0),
              [{{user_storage_events, ns_node_disco:ns_server_node()}, fun (_) -> true end}]
      end,
      fun () -> {get_auth_version(), get_users_version()} end).

empty_storage() ->
    replicated_dets:empty(storage_name()).

get_passwordless() ->
    gen_server:call(storage_name(), get_passwordless, infinity).

init([]) ->
    _ = ets:new(versions_name(), [protected, named_table]),
    #state{base = init_versions()}.

init_versions() ->
    Base = crypto:rand_uniform(0, 16#100000000),
    ets:insert_new(versions_name(), [{user_version, 0, Base}, {auth_version, 0, Base}]),
    gen_event:notify(user_storage_events, {user_version, {0, Base}}),
    gen_event:notify(user_storage_events, {auth_version, {0, Base}}),
    Base.

on_save(Docs, State) ->
    {MessagesToSend, NewState} =
        lists:foldl(
          fun (Doc, {MessagesAcc, StateAcc}) ->
                  case replicated_dets:get_id(Doc) of
                      {user, _} ->
                          {sets:add_element({change_version, user_version}, MessagesAcc), StateAcc};
                      {auth, Identity} ->
                          NState = maybe_update_passwordless(Identity,
                                                             replicated_dets:get_value(Doc),
                                                             replicated_dets:is_deleted(Doc),
                                                             StateAcc),
                          {sets:add_element({change_version, auth_version}, MessagesAcc), NState}
                  end
          end, {sets:new(), State}, Docs),
    lists:foreach(fun (Msg) ->
                          self() ! Msg
                  end, sets:to_list(MessagesToSend)),
    NewState.

handle_info({change_version, Key} = Msg, #state{base = Base} = State) ->
    misc:flush(Msg),
    Ver = ets:update_counter(versions_name(), Key, 1),
    gen_event:notify(user_storage_events, {Key, {Ver, Base}}),
    {noreply, State}.

on_empty(_State) ->
    true = ets:delete_all_objects(versions_name()),
    #state{base = init_versions()}.

maybe_update_passwordless(_Identity, _Value, _Deleted, State = #state{passwordless = undefined}) ->
    State;
maybe_update_passwordless(Identity, _Value, true, State = #state{passwordless = Passwordless}) ->
    State#state{passwordless = lists:delete(Identity, Passwordless)};
maybe_update_passwordless(Identity, Auth, false, State = #state{passwordless = Passwordless}) ->
    NewPasswordless =
        case authenticate_with_info(Auth, "") of
            true ->
                case lists:member(Identity, Passwordless) of
                    true ->
                        Passwordless;
                    false ->
                        [Identity | Passwordless]
                end;
            false ->
                lists:delete(Identity, Passwordless)
        end,
    State#state{passwordless = NewPasswordless}.

handle_call(get_passwordless, _From, TableName, #state{passwordless = undefined} = State) ->
    Passwordless =
        pipes:run(
          replicated_dets:select(TableName, {auth, '_'}, 100, true),
          ?make_consumer(
             pipes:fold(?producer(),
                        fun ({{auth, Identity}, Auth}, Acc) ->
                                case authenticate_with_info(Auth, "") of
                                    true ->
                                        [Identity | Acc];
                                    false ->
                                        Acc
                                end
                        end, []))),
    {reply, Passwordless, State#state{passwordless = Passwordless}};
handle_call(get_passwordless, _From, _TableName, #state{passwordless = Passwordless} = State) ->
    {reply, Passwordless, State}.

-spec get_users_45(ns_config()) -> [{rbac_identity(), []}].
get_users_45(Config) ->
    ns_config:search(Config, user_roles, []).

select_users(KeySpec) ->
    replicated_dets:select(storage_name(), {user, KeySpec}, 100).

select_auth_infos(KeySpec) ->
    replicated_dets:select(storage_name(), {auth, KeySpec}, 100).

build_auth(false, undefined) ->
    password_required;
build_auth(false, Password) ->
    build_memcached_auth(Password);
build_auth({_, _}, undefined) ->
    same;
build_auth({_, CurrentAuth}, Password) ->
    {Salt, Mac} = get_salt_and_mac(CurrentAuth),
    case ns_config_auth:hash_password(Salt, Password) of
        Mac ->
            case has_scram_hashes(CurrentAuth) of
                false ->
                    build_memcached_auth(Password);
                _ ->
                    same
            end;
        _ ->
            build_memcached_auth(Password)
    end.

build_memcached_auth(Password) ->
    [{MemcachedAuth}] = build_memcached_auth_info([{"x", Password}]),
    proplists:delete(<<"n">>, MemcachedAuth).

-spec store_user(rbac_identity(), rbac_user_name(), rbac_password(), [rbac_role()]) -> run_txn_return().
store_user(Identity, Name, Password, Roles) ->
    Props = case Name of
                undefined ->
                    [];
                _ ->
                    [{name, Name}]
            end,
    case cluster_compat_mode:is_cluster_spock() of
        true ->
            store_user_spock(Identity, Props, Password, Roles, ns_config:get());
        false ->
            store_user_45(Identity, Props, Roles)
    end.

store_user_45({UserName, external}, Props, Roles) ->
    ns_config:run_txn(
      fun (Config, SetFn) ->
              case menelaus_roles:validate_roles(Roles, Config) of
                  {_, []} ->
                      Identity = {UserName, saslauthd},
                      Users = get_users_45(Config),
                      NewUsers = lists:keystore(Identity, 1, Users,
                                                {Identity, [{roles, Roles} | Props]}),
                      {commit, SetFn(user_roles, NewUsers, Config)};
                  {_, BadRoles} ->
                      {abort, {error, roles_validation, BadRoles}}
              end
      end).

count_users() ->
    pipes:run(menelaus_users:select_users('_'),
              ?make_consumer(
                 pipes:fold(?producer(),
                            fun (_, Acc) ->
                                    Acc + 1
                            end, 0))).

check_limit(Identity) ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            true;
        false ->
            case count_users() >= ?MAX_USERS_ON_CE of
                true ->
                    user_exists(Identity);
                false ->
                    true
            end
    end.

store_user_spock({_UserName, Domain} = Identity, Props, Password, Roles, Config) ->
    CurrentAuth = replicated_dets:get(storage_name(), {auth, Identity}),
    case check_limit(Identity) of
        true ->
            case Domain of
                external ->
                    store_user_spock_with_auth(Identity, Props, same, Roles, Config);
                local ->
                    case build_auth(CurrentAuth, Password) of
                        password_required ->
                            {abort, password_required};
                        Auth ->
                            store_user_spock_with_auth(Identity, Props, Auth, Roles, Config)
                    end
            end;
        false ->
            {abort, too_many}
    end.

store_user_spock_with_auth(Identity, Props, Auth, Roles, Config) ->
    case menelaus_roles:validate_roles(Roles, Config) of
        {NewRoles, []} ->
            ok = store_user_spock_validated(Identity, [{roles, NewRoles} | Props], Auth),
            {commit, ok};
        {_, BadRoles} ->
            {abort, {error, roles_validation, BadRoles}}
    end.

store_user_spock_validated(Identity, Props, Auth) ->
    ok = replicated_dets:set(storage_name(), {user, Identity}, Props),
    case store_auth(Identity, Auth) of
        ok ->
            ok;
        unchanged ->
            ok
    end.

store_auth(_Identity, same) ->
    unchanged;
store_auth(Identity, Auth) when is_list(Auth) ->
    ok = replicated_dets:set(storage_name(), {auth, Identity}, Auth).

change_password({_UserName, local} = Identity, Password) when is_list(Password) ->
    case replicated_dets:get(storage_name(), {user, Identity}) of
        false ->
            user_not_found;
        _ ->
            CurrentAuth = replicated_dets:get(storage_name(), {auth, Identity}),
            Auth = build_auth(CurrentAuth, Password),
            store_auth(Identity, Auth)
    end.

-spec delete_user(rbac_identity()) -> run_txn_return().
delete_user(Identity) ->
    case cluster_compat_mode:is_cluster_spock() of
        true ->
            delete_user_spock(Identity);
        false ->
            delete_user_45(Identity)
    end.

delete_user_45({UserName, external}) ->
    Identity = {UserName, saslauthd},
    ns_config:run_txn(
      fun (Config, SetFn) ->
              case ns_config:search(Config, user_roles) of
                  false ->
                      {abort, {error, not_found}};
                  {value, Users} ->
                      case lists:keytake(Identity, 1, Users) of
                          false ->
                              {abort, {error, not_found}};
                          {value, _, NewUsers} ->
                              {commit, SetFn(user_roles, NewUsers, Config)}
                      end
              end
      end).

delete_user_spock({_, Domain} = Identity) ->
    case Domain of
        local ->
            _ = replicated_dets:delete(storage_name(), {auth, Identity});
        external ->
            ok
    end,
    case replicated_dets:delete(storage_name(), {user, Identity}) of
        {not_found, _} ->
            {abort, {error, not_found}};
        ok ->
            {commit, ok}
    end.

get_salt_and_mac(Auth) ->
    SaltAndMacBase64 = binary_to_list(proplists:get_value(<<"plain">>, Auth)),
    <<Salt:16/binary, Mac:20/binary>> = base64:decode(SaltAndMacBase64),
    {Salt, Mac}.

has_scram_hashes(Auth) ->
    proplists:is_defined(<<"sha1">>, Auth).

-spec authenticate(rbac_user_id(), rbac_password()) -> boolean().
authenticate(Username, Password) ->
    case cluster_compat_mode:is_cluster_spock() of
        true ->
            Identity = {Username, local},
            case get_auth_info(Identity) of
                false ->
                    false;
                Auth ->
                    authenticate_with_info(Auth, Password)
            end;
        false ->
            false
    end.

get_auth_info(Identity) ->
    case ns_node_disco:couchdb_node() == node() of
        false ->
            get_auth_info_on_ns_server(Identity);
        true ->
            versioned_cache:get(auth_cache_name(), Identity)
    end.

get_auth_info_on_ns_server(Identity) ->
    case replicated_dets:get(storage_name(), {user, Identity}) of
        false ->
            false;
        _ ->
            case replicated_dets:get(storage_name(), {auth, Identity}) of
                false ->
                    false;
                {_, Auth} ->
                    Auth
            end
    end.

-spec authenticate_with_info(list(), rbac_password()) -> boolean().
authenticate_with_info(Auth, Password) ->
    {Salt, Mac} = get_salt_and_mac(Auth),
    ns_config_auth:hash_password(Salt, Password) =:= Mac.

get_user_props_45({User, external}) ->
    ns_config:search_prop(ns_config:latest(), user_roles, {User, saslauthd}, []).

get_user_props(Identity) ->
    case cluster_compat_mode:is_cluster_spock() of
        true ->
            replicated_dets:get(storage_name(), {user, Identity}, []);
        false ->
            get_user_props_45(Identity)
    end.

-spec user_exists(rbac_identity()) -> boolean().
user_exists(Identity) ->
    get_user_props(Identity) =/= [].

-spec get_roles(rbac_identity()) -> [rbac_role()].
get_roles(Identity) ->
    proplists:get_value(roles, get_user_props(Identity), []).

-spec get_user_name(rbac_identity()) -> rbac_user_name().
get_user_name({_, Domain} = Identity) when Domain =:= local orelse Domain =:= external ->
    proplists:get_value(name, get_user_props(Identity));
get_user_name(_) ->
    undefined.

collect_result(Port, Acc) ->
    receive
        {Port, {exit_status, Status}} ->
            {Status, lists:flatten(lists:reverse(Acc))};
        {Port, {data, Msg}} ->
            collect_result(Port, [Msg | Acc])
    end.

build_memcached_auth_info(UserPasswords) ->
    Iterations = ns_config:read_key_fast(memcached_password_hash_iterations, 4000),
    Port = ns_ports_setup:run_cbsasladm(Iterations),
    lists:foreach(
      fun ({User, Password}) ->
              PasswordStr = User ++ " " ++ Password ++ "\n",
              ok = goport:write(Port, PasswordStr)
      end, UserPasswords),
    ok = goport:close(Port, stdin),
    {0, Json} = collect_result(Port, []),
    {[{<<"users">>, Infos}]} = ejson:decode(Json),
    Infos.

build_plain_memcached_auth_info(Salt, Mac) ->
    SaltAndMac = <<Salt/binary, Mac/binary>>,
    [{<<"plain">>, base64:encode(SaltAndMac)}].

collect_users(asterisk, _Role, Dict) ->
    Dict;
collect_users([], _Role, Dict) ->
    Dict;
collect_users([User | Rest], Role, Dict) ->
    NewDict = dict:update(User, fun (Roles) ->
                                        ordsets:add_element(Role, Roles)
                                end, ordsets:from_list([Role]), Dict),
    collect_users(Rest, Role, NewDict).

-spec upgrade_to_4_5(ns_config()) -> [{set, user_roles, _}].
upgrade_to_4_5(Config) ->
    case ns_config:search(Config, saslauthd_auth_settings) of
        false ->
            [];
        {value, Props} ->
            case proplists:get_value(enabled, Props, false) of
                false ->
                    [];
                true ->
                    Dict = dict:new(),
                    Dict1 = collect_users(proplists:get_value(admins, Props, []), admin, Dict),
                    Dict2 = collect_users(proplists:get_value(roAdmins, Props, []), ro_admin, Dict1),
                    [{set, user_roles,
                      lists:map(fun ({User, Roles}) ->
                                        {{binary_to_list(User), saslauthd},
                                         [{roles, ordsets:to_list(Roles)}]}
                                end, dict:to_list(Dict2))}]
            end
    end.

upgrade_to_4_5_test() ->
    Config = [[{saslauthd_auth_settings,
                [{enabled,true},
                 {admins,[<<"user1">>, <<"user2">>, <<"user1">>, <<"user3">>]},
                 {roAdmins,[<<"user4">>, <<"user1">>]}]}]],
    UserRoles = [{{"user1", saslauthd}, [{roles, [admin, ro_admin]}]},
                 {{"user2", saslauthd}, [{roles, [admin]}]},
                 {{"user3", saslauthd}, [{roles, [admin]}]},
                 {{"user4", saslauthd}, [{roles, [ro_admin]}]}],
    Upgraded = upgrade_to_4_5(Config),
    ?assertMatch([{set, user_roles, _}], Upgraded),
    [{set, user_roles, UpgradedUserRoles}] = Upgraded,
    ?assertMatch(UserRoles, lists:sort(UpgradedUserRoles)).

upgrade_to_4_5_asterisk_test() ->
    Config = [[{saslauthd_auth_settings,
                [{enabled,true},
                 {admins, asterisk},
                 {roAdmins,[<<"user1">>]}]}]],
    UserRoles = [{{"user1", saslauthd}, [{roles, [ro_admin]}]}],
    Upgraded = upgrade_to_4_5(Config),
    ?assertMatch([{set, user_roles, _}], Upgraded),
    [{set, user_roles, UpgradedUserRoles}] = Upgraded,
    ?assertMatch(UserRoles, lists:sort(UpgradedUserRoles)).

upgrade_to_spock(Config, Nodes) ->
    try
        Repair =
            case ns_config:search(Config, users_upgrade) of
                false ->
                    ns_config:set(users_upgrade, started),
                    false;
                {value, started} ->
                    ?log_debug("Found unfinished users upgrade. Continue."),
                    true
            end,
        do_upgrade_to_spock(Nodes, Repair),
        ok
    catch T:E ->
            ale:error(?USER_LOGGER, "Unsuccessful user storage upgrade.~n~p",
                      [{T,E,erlang:get_stacktrace()}]),
            error
    end.

do_upgrade_to_spock(Nodes, Repair) ->
    %% propagate users_upgrade to nodes
    case ns_config_rep:ensure_config_seen_by_nodes(Nodes) of
        ok ->
            ok;
        {error, BadNodes} ->
            throw({push_config, BadNodes})
    end,
    %% pull latest user information from nodes
    case ns_config_rep:pull_remotes(Nodes) of
        ok ->
            ok;
        Error ->
            throw({pull_config, Error})
    end,

    case Repair of
        true ->
            %% in case if aborted upgrade left some junk
            replicated_storage:sync_to_me(storage_name(),
                                          ns_config:read_key_fast(users_upgrade_timeout, 60000)),
            replicated_dets:delete_all(storage_name());
        false ->
            ok
    end,
    Config = ns_config:get(),
    AdminName =
        case ns_config_auth:get_creds(Config, admin) of
            undefined ->
                undefined;
            {AN, _} ->
                AN
        end,

    case ns_config_auth:get_creds(Config, ro_admin) of
        undefined ->
            ok;
        {ROAdmin, {Salt, Mac}} ->
            Auth = build_plain_memcached_auth_info(Salt, Mac),
            {commit, ok} =
                store_user_spock_with_auth({ROAdmin, local}, [{name, "Read Only User"}],
                                           Auth, [ro_admin], Config)
    end,

    lists:foreach(
      fun ({Name, _}) when Name =:= AdminName ->
              ?log_warning("Not creating user for bucket ~p, because the name matches administrators id",
                           [AdminName]);
          ({BucketName, BucketConfig}) ->
              Password = proplists:get_value(sasl_password, BucketConfig, ""),
              UUID = proplists:get_value(uuid, BucketConfig),
              Name = "Generated user for bucket " ++ BucketName,
              ok = store_user_spock_validated(
                     {BucketName, local},
                     [{name, Name}, {roles, [{bucket_full_access, [{BucketName, UUID}]}]}],
                     build_memcached_auth(Password))
      end, ns_bucket:get_buckets(Config)),

    LdapUsers = get_users_45(Config),
    lists:foreach(
      fun ({{LdapUser, saslauthd}, Props}) ->
              Roles = proplists:get_value(roles, Props),
              {ValidatedRoles, _} = menelaus_roles:validate_roles(Roles, Config),
              NewProps = lists:keystore(roles, 1, Props, {roles, ValidatedRoles}),
              ok = store_user_spock_validated({LdapUser, external}, NewProps, same)
      end, LdapUsers).

config_upgrade() ->
    [{delete, users_upgrade}, {delete, read_only_user_creds}].

upgrade_status() ->
    ns_config:read_key_fast(users_upgrade, undefined).

filter_out_invalid_roles(Props, Definitions, AllPossibleValues) ->
    Roles = proplists:get_value(roles, Props, []),
    FilteredRoles = menelaus_roles:filter_out_invalid_roles(Roles, Definitions, AllPossibleValues),
    lists:keystore(roles, 1, Props, {roles, FilteredRoles}).

cleanup_bucket_roles(BucketName) ->
    ?log_debug("Delete all roles for bucket ~p", [BucketName]),
    Buckets = lists:keydelete(BucketName, 1, ns_bucket:get_buckets()),
    Definitions = menelaus_roles:get_definitions(),
    AllPossibleValues = menelaus_roles:calculate_possible_param_values(Buckets),

    UpdateFun =
        fun ({user, Key}, Props) ->
                case menelaus_users:filter_out_invalid_roles(Props, Definitions,
                                                             AllPossibleValues) of
                    Props ->
                        skip;
                    NewProps ->
                        ?log_debug("Changing properties of ~p from ~p to ~p due to deletion of ~p",
                                   [Key, Props, NewProps, BucketName]),
                        {update, NewProps}
                end
        end,
    case replicated_dets:select_with_update(storage_name(), {user, '_'}, 100, UpdateFun) of
        [] ->
            ok;
        Errors ->
            ?log_warning("Failed to cleanup some roles: ~p", [Errors]),
            ok
    end.
