-module(mc_addr).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

create(Location, Kind) ->
     #mc_addr{location = Location, kind = Kind}.

