%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

-module(ns_license).

-export([license/0, license/1,
         change_license/1, change_license/2]).

license() ->
    license(node()).

license(_Node) ->
    %% TODO: License placeholder.
    %% We should read this out of a per-node-specific place in the ns_config.
    {"HDJ1-HQR1-23J4-3847", %% A string or the atom undefined if no license.
     {2010, 9, 15}          %% License is valid until this date, inclusive,
                            %% in {Y, M, D} format, or the atoms forever or invalid.
    }.

change_license(L) ->
    change_license(node(), L).

change_license(_Node, _L) ->
    todo.
