-module(mc_addr).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

create(Location, Kind) ->
     #mc_addr{location = Location, kind = Kind}.

location(Addr) -> Addr#mc_addr.location.
kind(Addr)     -> Addr#mc_addr.kind.

local(Kind) -> mc_addr:create("127.0.0.1:11211", Kind).

