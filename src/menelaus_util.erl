%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Supervisor for the menelaus application.

-module(menelaus_util).
-author('Northscale <info@northscale.com>').

%% External exports
-export([rest_url/3, rest_get/2]).

rest_url(Host, Port, Path) ->
    "http://" ++ Host ++ ":" ++ Port ++ Path.

rest_get(Url, undefined) ->
    http:request(Url);

rest_get(Url, {User, Password}) ->
    UserPassword = base64:encode_to_string(User ++ ":" ++ Password),
    http:request(get, {Url, [{"Authorization",
                              "Basic " ++ UserPassword}]}, [], []).

