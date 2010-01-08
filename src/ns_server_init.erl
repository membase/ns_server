% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_server_init).

-export([start_link/0, init/0]).

% Final initialization steps with a transient worker process.
%
start_link() ->
    {ok, spawn_link(?MODULE, init, [])}.

init() ->
    % Update our config from remote nodes that are already running.
    ns_node_disco:config_pull(),
    % And, we might have had changes even more recent that others.
    ns_node_disco:config_push(),
    % Have ns_config announce all its keys so callbacks get going.
    ns_config:reannounce(),
    ok.

