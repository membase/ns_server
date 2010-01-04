-module(mc_pool).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(mc_pool, {id,     % Pool id.
                  addrs,  % [mc_addr:create()*].
                  config, % From ns_config:get().
                  buckets % [mc_bucket:create()*].
                  }).

%% API for pool.

%% TODO: A proper implementation.
%% TODO: Consider replacing implementation with gen_server.

create(Id, Addrs, Config, Buckets) ->
    #mc_pool{id = Id, addrs = Addrs, config = Config, buckets = Buckets}.

% Returns {ok, Bucket} or false.
get_bucket(#mc_pool{buckets = Buckets}, BucketId) ->
    search_bucket(BucketId, Buckets).

nodes_to_addrs(Nodes, Port, Kind, Auth) ->
    PortStr = integer_to_list(Port),
    lists:map(fun(Node) ->
                  % Node is an atom like some_name@host.foo.bar.com
                  [_Name, Host | _] = string:tokens(atom_to_list(Node), '@'),
                  Location = Host ++ PortStr,
                  mc_addr:create(Location, Kind, Auth)
              end,
              Nodes).

% ------------------------------------------------

search_bucket(_BucketId, []) -> false;
search_bucket(BucketId, [Bucket | Rest]) ->
    case mc_bucket:id(Bucket) =:= BucketId of
        true  -> {ok, Bucket};
        false -> search_bucket(BucketId, Rest)
    end.

foreach_bucket(#mc_pool{buckets = Buckets}, VisitorFun) ->
    lists:foreach(VisitorFun, Buckets).

% ------------------------------------------------

get_bucket_test() ->
    B1 = mc_bucket:create("default", [mc_addr:local(ascii)], []),
    Addrs = [mc_addr:local(ascii)],
    P1 = create(p1, Addrs, config,
                [mc_bucket:create("default", Addrs, [])]),
    ?assertMatch({ok, B1}, get_bucket(P1, "default")),
    ok.

foreach_bucket_test() ->
    B1 = mc_bucket:create("default", [mc_addr:local(ascii)], []),
    Addrs = [mc_addr:local(ascii)],
    P1 = create(p1, Addrs, config,
                [mc_bucket:create("default", Addrs, [])]),
    foreach_bucket(P1, fun (B) ->
                           ?assertMatch(B1, B)
                       end),
    ok.

