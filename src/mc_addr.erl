-module(mc_addr).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% Note: we may use mc_addr as keys in dict/ets tables,
%       so they need to be scalar-ish or matchable.

-record(mc_addr, {location, % eg, "localhost:11211"
                  kind      % eg, binary or ascii
                  % TODO: bucket name? pool name? auth creds?
                  }).

create(Location, Kind) ->
     #mc_addr{location = Location, kind = Kind}.

location(Addr) -> Addr#mc_addr.location.
kind(Addr)     -> Addr#mc_addr.kind.

local(Kind) -> mc_addr:create("127.0.0.1:11211", Kind).

