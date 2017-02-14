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
%% @doc handling of memcached permissions file

-module(memcached_permissions).

-behaviour(memcached_cfg).

-export([start_link/0, sync/0]).

%% callbacks
-export([init/0, filter_event/1, handle_event/2, generate/1, refresh/0]).

-include("ns_common.hrl").

-include_lib("eunit/include/eunit.hrl").

-record(state, {buckets,
                users,
                roles,
                admin_user}).

bucket_permissions_to_check(Bucket) ->
    [{{[{bucket, Bucket}, data, docs], read},  'Read'},
     {{[{bucket, Bucket}, data, docs], write}, 'Write'},
     {{[{bucket, Bucket}, stats], read},       'SimpleStats'},
     {{[{bucket, Bucket}, data, dcp], read},   'DcpConsumer'},
     {{[{bucket, Bucket}, data, dcp], write},  'DcpProducer'},
     {{[{bucket, Bucket}, data, tap], read},   'TapConsumer'},
     {{[{bucket, Bucket}, data, tap], write},  'TapProducer'},
     {{[{bucket, Bucket}, data, meta], read},  'MetaRead'},
     {{[{bucket, Bucket}, data, meta], write}, 'MetaWrite'},
     {{[{bucket, Bucket}, data, idle], read},  'IdleConnection'},
     {{[{bucket, Bucket}, data, xattr], read}, 'XattrRead'},
     {{[{bucket, Bucket}, data, xattr], write},'XattrWrite'}].

global_permissions_to_check() ->
    [{{[stats, memcached], read},           'Stats'},
     {{[buckets], create},                  'BucketManagement'},
     {{[admin, memcached, node], write},    'NodeManagement'},
     {{[admin, memcached, session], write}, 'SessionManagement'},
     {{[admin, security, audit], write},    'AuditManagement'}].

start_link() ->
    Path = ns_config:search_node_prop(ns_config:latest(), memcached, rbac_file),
    memcached_cfg:start_link(?MODULE, Path).

sync() ->
    memcached_cfg:sync(?MODULE).

init() ->
    Config = ns_config:get(),
    #state{buckets = ns_bucket:get_bucket_names(ns_bucket:get_buckets(Config)),
           users = trim_users(menelaus_users:get_users(Config)),
           admin_user = ns_config:search_node_prop(Config, memcached, admin_user),
           roles = menelaus_roles:get_definitions(Config)}.

filter_event({buckets, _V}) ->
    true;
filter_event({user_roles, _V}) ->
    true;
filter_event({roles_definitions, _V}) ->
    true;
filter_event(_) ->
    false.

handle_event({buckets, V}, #state{buckets = Buckets} = State) ->
    Configs = proplists:get_value(configs, V),
    case ns_bucket:get_bucket_names(Configs) of
        Buckets ->
            unchanged;
        NewBuckets ->
            {changed, State#state{buckets = NewBuckets}}
    end;
handle_event({user_roles, V}, #state{users = Users} = State) ->
    case trim_users(V) of
        Users ->
            unchanged;
        NewUsers ->
            {changed, State#state{users = NewUsers}}
    end;
handle_event({roles_definitions, V}, #state{roles = V}) ->
    unchanged;
handle_event({roles_definitions, NewRoles}, #state{roles = _V} = State) ->
    {changed, State#state{roles = NewRoles}}.

generate(#state{buckets = Buckets,
                users = Users,
                roles = RoleDefinitions,
                admin_user = Admin}) ->
    Json =
        {[memcached_admin_json(Admin, Buckets) | generate_json(Buckets, RoleDefinitions, Users)]},
    menelaus_util:encode_json(Json).

refresh() ->
    ns_memcached:connect_and_send_rbac_refresh().

trim_users(Users) ->
    [{menelaus_users:get_identity(User), menelaus_users:get_roles(User)} ||
        User <- Users].

bucket_permissions(Bucket, CompiledRoles) ->
    lists:usort([MemcachedPermission ||
                    {Permission, MemcachedPermission} <- bucket_permissions_to_check(Bucket),
                    menelaus_roles:is_allowed(Permission, CompiledRoles)]).

global_permissions(CompiledRoles) ->
    lists:usort([MemcachedPermission ||
                    {Permission, MemcachedPermission} <- global_permissions_to_check(),
                    menelaus_roles:is_allowed(Permission, CompiledRoles)]).

permissions_for_role(Buckets, RoleDefinitions, Role) ->
    CompiledRoles = menelaus_roles:compile_roles([Role], RoleDefinitions),
    [{global, global_permissions(CompiledRoles)} |
     [{Bucket, bucket_permissions(Bucket, CompiledRoles)} || Bucket <- Buckets]].

permissions_for_role(Buckets, RoleDefinitions, Role, RolesDict) ->
    case dict:find(Role, RolesDict) of
        {ok, Permissions} ->
            {Permissions, RolesDict};
        error ->
            Permissions = permissions_for_role(Buckets, RoleDefinitions, Role),
            {Permissions, dict:store(Role, Permissions, RolesDict)}
    end.

zip_permissions(Permissions, PermissionsAcc) ->
    lists:zipwith(fun ({Bucket, Perm}, {Bucket, PermAcc}) ->
                          {Bucket, [Perm | PermAcc]}
                  end, Permissions, PermissionsAcc).

permissions_for_user(Roles, Buckets, RoleDefinitions, RolesDict) ->
    Acc0 = [{global, []} | [{Bucket, []} || Bucket <- Buckets]],
    {ZippedPermissions, NewRolesDict} =
        lists:foldl(fun (Role, {Acc, Dict}) ->
                            {Permissions, NewDict} =
                                permissions_for_role(Buckets, RoleDefinitions, Role, Dict),
                            {zip_permissions(Permissions, Acc), NewDict}
                    end, {Acc0, RolesDict}, Roles),
    MergedPermissions = [{Bucket, lists:umerge(Perm)} || {Bucket, Perm} <- ZippedPermissions],
    {MergedPermissions, NewRolesDict}.

jsonify_user({UserName, Type}, [{global, GlobalPermissions} | BucketPermissions]) ->
    Buckets = {buckets, {[{list_to_binary(BucketName), Permissions} ||
                             {BucketName, Permissions} <- BucketPermissions]}},
    Global = {privileges, GlobalPermissions},
    {list_to_binary(UserName), {[Buckets, Global, {type, Type}]}}.

memcached_admin_json(AU, Buckets) ->
    jsonify_user({AU, builtin}, [{global, [all]} | [{Name, [all]} || Name <- Buckets]]).

generate_json(Buckets, RoleDefinitions, Users) ->
    RolesDict = dict:new(),
    BucketUsers = [{{Name, builtin}, menelaus_roles:get_roles({Name, bucket})} ||
                      Name <- Buckets],
    {Json, _} =
        lists:foldl(fun ({Identity, Roles}, {Acc, Dict}) ->
                            {Permissions, NewDict} =
                                permissions_for_user(Roles, Buckets, RoleDefinitions, Dict),
                            {[jsonify_user(Identity, Permissions) | Acc], NewDict}
                    end, {[], RolesDict}, BucketUsers ++ Users),
    lists:reverse(Json).

generate_json_test() ->
    Buckets = ["default", "test"],
    Users = [{{"ivanivanov", builtin}, [{views_admin, ["default"]}, {bucket_admin, ["test"]}]},
             {{"petrpetrov", saslauthd}, [admin]}],
    RoleDefinitions = menelaus_roles:preconfigured_roles(),

    Json =
        [{<<"default">>,
          {[{buckets,{[{<<"default">>,
                        ['DcpConsumer','DcpProducer','IdleConnection','MetaRead',
                         'MetaWrite','Read','SimpleStats','TapConsumer',
                         'TapProducer','Write','XattrRead','XattrWrite']},
                       {<<"test">>,[]}]}},
            {privileges,[]},
            {type, builtin}]}},
         {<<"test">>,
          {[{buckets,{[{<<"default">>,[]},
                       {<<"test">>,
                        ['DcpConsumer','DcpProducer','IdleConnection','MetaRead',
                         'MetaWrite','Read','SimpleStats','TapConsumer',
                         'TapProducer','Write','XattrRead','XattrWrite']}]}},
            {privileges,[]},
            {type, builtin}]}},
         {<<"ivanivanov">>,
          {[{buckets,{[{<<"default">>,
                        ['DcpConsumer','IdleConnection','MetaRead','Read',
                         'TapConsumer','XattrRead']},
                       {<<"test">>,
                        ['DcpConsumer','DcpProducer','IdleConnection','MetaRead',
                         'MetaWrite','Read','SimpleStats','TapConsumer',
                         'TapProducer','Write','XattrRead','XattrWrite']}]}},
            {privileges,['Stats']},
            {type, builtin}]}},
         {<<"petrpetrov">>,
          {[{buckets,{[{<<"default">>,
                        ['DcpConsumer','DcpProducer','IdleConnection','MetaRead',
                         'MetaWrite','Read','SimpleStats','TapConsumer',
                         'TapProducer','Write','XattrRead','XattrWrite']},
                       {<<"test">>,
                        ['DcpConsumer','DcpProducer','IdleConnection','MetaRead',
                         'MetaWrite','Read','SimpleStats','TapConsumer',
                         'TapProducer','Write','XattrRead','XattrWrite']}]}},
            {privileges,['AuditManagement','BucketManagement',
                         'NodeManagement','SessionManagement','Stats']},
            {type, saslauthd}]}}],
    ?assertEqual(Json, generate_json(Buckets, RoleDefinitions, Users)).
