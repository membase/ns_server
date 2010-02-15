% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(mc_addr).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: we may use mc_addr as keys in dict/ets tables,
%       so they need to be scalar-ish or matchable.

-record(mc_addr, {location, % eg, "localhost:11211"
                  kind,     % eg, binary or ascii
                  auth      % undefined, or {Mech, AuthData},
                            % eg, {<<"PLAIN">>, {AuthName, AuthPswd}}.
                            % eg, {<<"PLAIN">>, {ForName, AuthName, AuthPswd}}.
                  % TODO: bucket id, one day when we have bucket selection.
                  }).

create(Location, Kind) -> create(Location, Kind, undefined).

create(Location, Kind, Auth) ->
     #mc_addr{location = Location, kind = Kind, auth = Auth}.

location(Addr) -> Addr#mc_addr.location.
kind(Addr)     -> Addr#mc_addr.kind.
auth(Addr)     -> Addr#mc_addr.auth.

local(Kind) -> mc_addr:create("127.0.0.1:11211", Kind).

