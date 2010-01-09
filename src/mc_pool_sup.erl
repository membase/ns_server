% Copyright (c) 2009, NorthScale, Inc
% Copyright (c) 2008, Cliff Moon
% Copyright (c) 2008, Powerset, Inc
%
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions
% are met:
%
% * Redistributions of source code must retain the above copyright
% notice, this list of conditions and the following disclaimer.
% * Redistributions in binary form must reproduce the above copyright
% notice, this list of conditions and the following disclaimer in the
% documentation and/or other materials provided with the distribution.
% * Neither the name of Powerset, Inc nor the names of its
% contributors may be used to endorse or promote products derived from
% this software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
% FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
% COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
% CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
% ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
% POSSIBILITY OF SUCH DAMAGE.
%
% Original Author: Cliff Moon

-module(mc_pool_sup).

-behaviour(supervisor).

-export([start_link/1, init/1, current_children/0]).

-include_lib("eunit/include/eunit.hrl").

start_link(Name) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, Name).

% mc_pull_sup children are dynamic...
%
%     {pool, "default"} {gen_server} keeps buckets map & state
%       permanent so that REST kvcache pathway works
%     {accept, "default"} {spawn_link} 11211| might not start if port conflict)
%       session-loop_in {spawn_link} mc_pool-default
%         session-loop_out {spawn_link}}
%       ...
%       session-loop_in {spawn_link} mc_pool-default
%         session-loop_out {spawn_link}}
%
% Need to kill pool & accept if pool removed.
% Need to restart accept if port changes.

init(Name) ->
    case ns_config:search_prop(ns_config:get(), pools, Name) of
        undefined -> ns_log:log(?MODULE, 0001, "missing pool config: ~p",
                                [Name]),
                     {error, einval};
        Config ->
            AddrStr = proplists:get_value(address, Config, "0.0.0.0"),
            PortNum = proplists:get_value(port, Config, 11211),
            Env = {mc_server_detect,
                   mc_server_detect,
                   {mc_pool, Name}},
            Children = [{mc_pool, {mc_pool, start_link, [Name]},
                         permanent, 10, worker, []},
                        {mc_accept, {mc_accept, start_link,
                                     [PortNum, AddrStr, Env]},
                         transient, 10, worker, []}],
            {ok, {{rest_for_one, 3, 10}, Children}}
    end.

current_children() ->
    % Children will look like...
    %   [{mc_pool,<0.77.0>,worker,[_]},
    %    {mc_accept,<0.78.0>,worker,[_]}]
    %
    Children1 = supervisor:which_children(?MODULE),
    lists:foldl(fun({Id, Pid, _, _} = X, Acc) ->
                    case is_pid(Pid) of
                        true  -> [X | Acc];
                        false -> supervisor:delete_child(?MODULE, Id),
                                 Acc
                    end
                end,
                [],
                Children1).

