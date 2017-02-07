%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc - This module contains the logic to reprovision a bucket when
%% the active vbuckets are found to be in "missing" state. Typically,
%% such a scenario would arise in case of ephemeral buckets when the
%% memcached process on a node restarts within the auto-failover
%% timeout.
-module(auto_reprovision).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start_link/0]).

%% APIs.
-export([
         enable/1,
         disable/0,
         reset_count/0
        ]).

%% gen_server callbacks.
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_MAX_NODES_SUPPORTED, 1).

-record(state, {enabled = false :: boolean(),
                max_nodes = ?DEFAULT_MAX_NODES_SUPPORTED :: integer(),
                count = 0 :: integer()}).

start_link() ->
    misc:start_singleton(gen_server, ?MODULE, [], []).

%% APIs.
-spec enable(integer()) -> ok.
enable(MaxNodes) ->
    call({enable, MaxNodes}).

-spec disable() -> ok.
disable() ->
    call(disable).

-spec reset_count() -> ok.
reset_count() ->
    call(reset_count).

call(Msg) ->
    misc:wait_for_global_name(?MODULE),
    gen_server:call({global, ?MODULE}, Msg, 5000).

%% gen_server callbacks.
init([]) ->
    {Enabled, MaxNodes, Count} = get_reprovision_cfg(),
    {ok, #state{enabled = Enabled, max_nodes = MaxNodes, count = Count}}.

handle_call({enable, MaxNodes}, _From, #state{count = Count} = State) ->
    ale:info(?USER_LOGGER, "Enabled auto-reprovision config with max_nodes set to ~p", [MaxNodes]),
    ok = persist_config(true, MaxNodes, Count),
    {reply, ok, State#state{enabled = true, max_nodes = MaxNodes, count = Count}};
handle_call(disable, _From, _State) ->
    ok = persist_config(false, ?DEFAULT_MAX_NODES_SUPPORTED, 0),
    {reply, ok, #state{}};
handle_call(reset_count, _From, State) ->
    {Enabled, MaxNodes, Count} = get_reprovision_cfg(),
    ale:info(?USER_LOGGER, "auto-reprovision count reset from ~p", [Count]),
    ok = persist_config(Enabled, MaxNodes, 0),
    {reply, ok, State#state{count = 0}}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Internal functions.
persist_config(Enabled, MaxNodes, Count) ->
    ns_config:set(auto_reprovision_cfg,
                  [{enabled, Enabled},
                   {max_nodes, MaxNodes},
                   {count, Count}]).

get_reprovision_cfg() ->
    {value, RCfg} = ns_config:search(ns_config:latest(), auto_reprovision_cfg),
    {proplists:get_value(enabled, RCfg, false),
     proplists:get_value(max_nodes, RCfg, ?DEFAULT_MAX_NODES_SUPPORTED),
     proplists:get_value(count, RCfg, 0)}.
