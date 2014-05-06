-module(proxied_memcached_clients_pool).

-include("ns_common.hrl").
-include("remote_clusters_info.hrl").

-export([start_link/0,
         make_proxied_loc/7]).

-export([take_socket/1, put_socket/2]).

start_link() ->
    Options = [{name, proxied_memcached_clients_pool},
               {connection_timeout, 30000},
               {pool_size, 200}],
    ns_connection_pool:start_link(Options).

take_socket({?MODULE, {Host, Port, Bucket, Auth, LP, RP, Cert}}) ->
    RV = case ns_connection_pool:maybe_take_socket(proxied_memcached_clients_pool, {Host, Port, Bucket}) of
             {ok, _S} = Ok ->
                 Ok;
             no_socket ->
                 establish_connection(Host, Port, Bucket, Auth, LP, RP, Cert)
         end,
    case RV of
        {ok, S} ->
            {ok, {batch_socket, S}};
        _ ->
            RV
    end.

establish_connection(Host, Port, Bucket, Password, LP, RP, Cert) ->
    ?log_debug("Host, Port, Bucket, LP, RP: ~p", [{Host, Port, Bucket, LP, RP}]),
    case gen_tcp:connect("127.0.0.1", LP, [binary, {packet, 0}, {nodelay, true}, {active, false}]) of
        {ok, S} ->
            case (catch ns_ssl:establish_ssl_proxy_connection(S, Host, Port, RP, Cert,
                                                              Bucket, Password)) of
                ok ->
                    {ok, S};
                Err ->
                    {error, {proxy_error, Err}}
            end;
        {error, _} = Error ->
            Error
    end.

put_socket({batch_socket, Socket}, {?MODULE, {Host, Port, Bucket, _Auth, _LP, _RP, _Cert}}) ->
    ns_connection_pool:put_socket(proxied_memcached_clients_pool, {Host, Port, Bucket}, Socket).

make_proxied_loc(Host, Port, Bucket, Password, LP, RP, Cert) ->
    {?MODULE, {Host, Port, Bucket, Password, LP, RP, Cert}}.
