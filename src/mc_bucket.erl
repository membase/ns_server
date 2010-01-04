-module(mc_bucket).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(mc_bucket, {id,    % Bucket id.
                    auth,
                    addrs, % [mc_addr:create()*].
                    cring, % From cring:create().
                    config % From ns_config:get().
                    }).

%% API for buckets.

% Callers should consider the returned value to be opaque.
% One day, the return value, for example, might be changed
% into a gen_server Pid.
%
% Addrs is a list of mc_addr:create() records.
%
% For 1.0, these Addrs are to kvcache servers, not to the routers.
%
create(Id, Addrs, Config) ->
    create(Id, Addrs, Config, ketama, ketama:default_config()).

create(Id, Addrs, Config, HashMod, HashCfg) ->
    CRingAddrs =
        lists:map(fun(Addr) ->
                      Location = mc_addr:location(Addr),
                      [Host, Port | _] = string:tokens(Location, ":"),
                      PortNum = list_to_integer(Port),
                      {{Host, PortNum}, Addr}
                  end,
                  Addrs),
    CRing = cring:create(CRingAddrs, HashMod, HashCfg),
    #mc_bucket{id = Id,
               addrs = Addrs,
               cring = CRing,
               config = Config}.

id(#mc_bucket{id = Id})          -> Id.
addrs(#mc_bucket{addrs = Addrs}) -> Addrs.

auth_needed(_Bucket) -> false.

auth_ok(#mc_bucket{auth = Auth}) -> Auth.

% Choose the Addr that should contain the Key.
choose_addr(#mc_bucket{cring = CRing}, Key) ->
    case cring:search(CRing, Key) of
        false     -> false;
        {_, Addr} -> {Key, Addr}
    end.

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The number of Addr's returned
% is based on Bucket default replication level.
choose_addrs(Bucket, Key) ->
    % For 1.0, no replication.
    choose_addrs(Bucket, Key, 1).

% Choose several Addr's that should contain the Key given replication,
% with the primary Addr coming first.  The result Addr's list might
% have length <= N.
choose_addrs(#mc_bucket{cring = CRing, config = Config}, Key, N) ->
    CRingAddrDataList = cring:search(CRing, Key, N),
    Addrs = lists:map(fun({_CRingAddr, Addr}) -> Addr end,
                      CRingAddrDataList),
    {Key, Addrs, Config}.

% ------------------------------------------------

% Fake hash_key/hash_addr functions for unit testing.

hash_key(_Key, _)   -> 1.
hash_addr(_Addr, _) -> [1].

choose_addr_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, ?MODULE, 1),
    ?assertMatch({key1, A1}, choose_addr(B1, key1)),
    ?assertMatch({key2, A1}, choose_addr(B1, key2)),
    ok.

choose_addrs_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, ?MODULE, 1),
    ?assertMatch({key5, [A1], config}, choose_addrs(B1, key5, 1)),
    ?assertMatch({key6, [A1], config}, choose_addrs(B1, key6, 1)),
    ok.

choose_addr_str_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, ?MODULE, 1),
    ?assertMatch({"key1", A1}, choose_addr(B1, "key1")),
    ?assertMatch({"key2", A1}, choose_addr(B1, "key2")),
    ok.

choose_addrs_str_test() ->
    A1 = mc_addr:create("127.0.0.1:11211", ascii),
    B1 = create(buck1, [A1], config, ?MODULE, 1),
    ?assertMatch({"key5", [A1], config}, choose_addrs(B1, "key5", 1)),
    ?assertMatch({"key6", [A1], config}, choose_addrs(B1, "key6", 1)),
    ok.

