-module(memcached_clients_pool).

-include("ns_common.hrl").

-export([start_link/0,
         make_loc/5]).

-export([take_socket/1, put_socket/2]).

start_link() ->
    Options = [{name, memcached_clients_pool},
               {connection_timeout, 30000},
               {pool_size, 200}],
    ns_connection_pool:start_link(Options).

take_socket({?MODULE, {Host, Port, Bucket, Auth, Enchancer}}) ->
    case ns_connection_pool:maybe_take_socket(memcached_clients_pool,
                                              {Host, Port, Bucket, Enchancer}) of
        {ok, _S} = Ok ->
            Ok;
        no_socket ->
            establish_connection(Host, Port, Bucket, Auth, Enchancer)
    end.

establish_connection(Host, Port, Bucket, Password, Enchancer) ->
    case gen_tcp:connect(Host, Port, [binary, {packet, 0}, {keepalive, true}, {nodelay, true}, {active, false}]) of
        {ok, S} ->
            case mc_client_binary:auth(S, {<<"PLAIN">>,
                                           {list_to_binary(Bucket),
                                            list_to_binary(Password)}}) of
                ok ->
                    case Enchancer of
                        [] ->
                            {ok, S};
                        _ ->
                            ok = Enchancer:enchance_socket(S),
                            {ok, S}
                    end;
                {memcached_error, _, _} = McdError ->
                    {error, {auth_failed, McdError}}
            end;
        {error, _ } = Error ->
            Error
    end.

put_socket(Socket, {?MODULE, {Host, Port, Bucket, _Auth, Enchancer}}) ->
    ns_connection_pool:put_socket(memcached_clients_pool,
                                  {Host, Port, Bucket, Enchancer}, Socket).

make_loc(Host, Port, Bucket, Password, Enchancer) ->
    {?MODULE, {Host, Port, Bucket, Password, Enchancer}}.
