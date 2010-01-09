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

-module(emoxi_sup).

-behaviour(supervisor).

-export([start_link/0, init/1,
         start_pool/1, stop_pool/1,
         current_pools/0]).

-include_lib("eunit/include/eunit.hrl").

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = child_specs(),
    {ok, {{one_for_one, 3, 10}, Children}}.

% emoxi_sup (one_for_one)
%
%   mc_downstream
%     Children are dynamic worker* (one worker per Addr (host/port/auth)
%     processes, where the child workers are monitorable.  A child worker
%     process automatically dies after inactivity)
%
%   mc_pool_init {gen_event listener, watches ns_config}
%     This process watches the ns_config 'pools' key and
%     for each pool-XXX entry keep mc_pool_sup children sync'ed.
%
%   {mc_pool_sup, Name}*
%     Multiple dynamic children, implemented by mc_pool_sup,
%     one supervisor for each named pool.

child_specs() ->
    [{mc_downstream,
      {mc_downstream, start_link, []},
      permanent, 1000, worker, [mc_downstream]},
     {mc_pool_init,
      {mc_pool_init, start_link, []},
      transient, 1000, worker, [mc_pool_init]}
    ].

current_pools() ->
    % Children will look like...
    %   [{mc_downstream,<0.77.0>,worker,[_]},
    %    {mc_pool_init,<0.78.0>,worker,[_]},
    %    {{mc_pool_sup, Name},<0.79.0>,supervisor,[_]}]
    %
    % Or possibly, if a child died, like...
    %   [{mc_downstream,undefined,worker,[_]},
    %    {mc_pool_init,undefined,worker,[_]},
    %    {{mc_pool_sup, Name},undefined,supervisor,[_]}]
    %
    % We only return the alive mc_pool_sup children as a
    % list of Name strings.
    %
    Children1 = supervisor:which_children(?MODULE),
    Children2 = proplists:delete(mc_downstream, Children1),
    Children3 = proplists:delete(mc_pool_init, Children2),
    lists:foldl(fun({{mc_pool_sup, Name} = Id, Pid, _, _}, Acc) ->
                        case is_pid(Pid) of
                            true  -> [Name | Acc];
                            false -> supervisor:delete_child(?MODULE, Id),
                                     Acc
                        end;
                   (_, Acc) -> Acc
                end,
                [],
                Children3).

start_pool(Name) ->
    case lists:member(Name, current_pools()) of
        false ->
            ChildSpec =
                {{mc_pool_sup, Name},
                 {mc_pool_sup, start_link, [Name]},
                 permanent, 10, supervisor, [mc_pool_sup]},
            {ok, C} = supervisor:start_child(?MODULE, ChildSpec),
            error_logger:info_msg("new mc_pool_sup: ~p~n", [C]),
            {ok, C};
        true ->
            {error, alreadystarted}
    end.

stop_pool(Name) ->
    Id = {mc_pool_sup, Name},
    supervisor:terminate_child(?MODULE, Id),
    supervisor:delete_child(?MODULE, Id),
    ok.
