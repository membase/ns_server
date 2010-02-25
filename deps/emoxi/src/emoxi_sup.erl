% Copyright (c) 2010, NorthScale, Inc
% All rights reserved.

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
    [{mc_downstream_sup,
      {mc_downstream_sup, start_link, []},
      permanent, 1000, supervisor, [mc_downstream_sup]},
     {mc_downstream,
      {mc_downstream, start_link, []},
      permanent, 1000, worker, [mc_downstream]},
     {mc_pool_events,
                 {gen_event, start_link, [{local, mc_pool_events}]},
                 permanent, 10, worker, []},
     {mc_pool_init,
      {mc_pool_init, start_link, []},
      transient, 1000, worker, [mc_pool_init]},
     {tgen,
      {tgen, start_link, []},
      permanent, 1000, worker, [tgen]}
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
    % We only return the mc_pool_sup children as a list of Name
    % strings.
    %

    %% These should never be dead (contrary to the above comment), as
    %% they're permanent with a restart strategy.  If someone is
    %% uncomfortable with this idea, it's possible to further assert
    %% it here, though it should probably include a comment describing
    %% exactly how one might end up dead.
    Rv = lists:filter(fun({{mc_pool_sup, _}, _, _, _}) -> true;
                         ({_, _, _, _}) -> false
                      end,
                      supervisor:which_children(?MODULE)),

    %% Only returning their names.
    lists:map(fun({{mc_pool_sup, Name}, _, _, _}) -> Name end, Rv).

%% Return {ok, Child} or {error, {already_started, Child}}
start_pool(Name) ->
    ChildSpec = {{mc_pool_sup, Name},
                 {mc_pool_sup, start_link, [Name]},
                 permanent, 10, supervisor, [mc_pool_sup]},
    supervisor:start_child(?MODULE, ChildSpec).

stop_pool(Name) ->
    Id = {mc_pool_sup, Name},
    supervisor:terminate_child(?MODULE, Id),
    supervisor:delete_child(?MODULE, Id),
    ok.
