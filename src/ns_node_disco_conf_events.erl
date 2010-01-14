% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_node_disco_conf_events).

-behaviour(gen_event).

%% gen_event callbacks
-export([start_link/0, init/1, handle_event/2, handle_call/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {disco}).

% start_link is required by gen_event, but *never* makes sense because
% the event handlers are not processes.
start_link() ->
    error.

init(DiscoPid) ->
    {ok, #state{disco=DiscoPid}, hibernate}.

terminate(_Reason, _State)     -> ok.
code_change(_OldVsn, State, _) -> {ok, State}.
handle_info(_Info, State)      -> {ok, State, hibernate}.
handle_call(_Request, State)   -> {ok, ok, State, hibernate}.

handle_event({nodes_wanted, _V}, State) ->
    error_logger:info_msg("ns_node_disco_conf_events config on nodes_wanted~n"),
    % The event may get to us really late, so don't pass along the param.
    ns_node_disco:nodes_wanted_updated(),
    {ok, State, hibernate};

handle_event({otp, _V}, State) ->
    error_logger:info_msg("ns_node_disco_conf_events config on otp~n"),
    % The event may get to us really late, so don't pass along the param.
    ns_node_disco:nodes_wanted_updated(),
    {ok, State, hibernate};

handle_event(Changed, State) when is_list(Changed) ->
    Config = ns_config:get(),
    ChangedRaw =
        lists:foldl(fun({Key, _}, Acc) ->
                            case ns_config:search_raw(Config, Key) of
                                false           -> Acc;
                                {value, RawVal} -> [{Key, RawVal} | Acc]
                            end;
                       (_, Acc) -> Acc
                    end,
                    [], Changed),
    ns_config_rep:push(ChangedRaw),
    {ok, State, hibernate};

handle_event(_E, State) ->
    {ok, State, hibernate}.


