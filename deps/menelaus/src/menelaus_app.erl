%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Callbacks for the menelaus application.

-module(menelaus_app).
-author('Northscale <info@northscale.com>').

-behaviour(application).
-export([start/2,stop/1,start_subapp/0]).
-export([ns_log_cat/1, ns_log_code_string/1]).

-define(START_OK, 1).
-define(START_FAIL, 2).

%% @spec start(_Type, _StartArgs) -> ServerRet
%% @doc application start callback for menelaus.
start(_Type, _StartArgs) ->
    start_subapp().

start_subapp() ->
    menelaus_deps:ensure(),
    Result = menelaus_sup:start_link(),
    WConfig = menelaus_web:webconfig(),
    Port = proplists:get_value(port, WConfig),
    case Result of
        {ok, _Pid} ->
            ns_log:log(?MODULE, ?START_OK,
                       "NorthScale Server has started on web port ~p on node ~p.",
                       [Port, node()]);
        _Err ->
            %% The exact error message is not logged here since this
            %% is a supervisor start, but a more helpful message
            %% should've been logged before.
            ns_log:log(?MODULE, ?START_FAIL,
                       "NorthScale Server has failed to start on web port ~p on node ~p. " ++
                       "Perhaps another process has taken port ~p already? " ++
                       "If so, please stop that process first before trying again.",
                       [Port, node(), Port])
    end,
    Result.

%% @spec stop(_State) -> ServerRet
%% @doc application stop callback for menelaus.
stop(_State) ->
    ok.

ns_log_cat(?START_OK) ->
    info;
ns_log_cat(?START_FAIL) ->
    crit.

ns_log_code_string(?START_OK) ->
    "web start ok";
ns_log_code_string(?START_FAIL) ->
    "web start fail".
