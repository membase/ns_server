% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(mc_info).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

%% API
-export([version/0]).

version() ->
    VA = case catch(ns_info:version()) of
             X when is_list(X) -> X;
             _                 -> []
         end,
    V = case proplists:get_value(ns_server, VA) of
            undefined -> case proplists:get_value(emoxi, VA) of
                             undefined -> "unknown";
                             X2        -> X2
                         end;
            X3 -> X3
        end,
    "northscale_proxy-" ++ V.

