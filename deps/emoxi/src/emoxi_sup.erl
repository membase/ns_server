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
     {mc_pool_init,
      {mc_pool_init, start_link, []},
      transient, 1000, worker, [mc_pool_init]},
     {tgen,
      {tgen, start_link, []},
      transient, 1000, worker, [tgen]}
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
    Children4 = proplists:delete(tgen, Children3),
    %% Some children will be dead.  Unsupervise those.
    {Rv, Dead} = lists:partition(fun({_, Pid, _, _}) -> is_pid(Pid) end, Children4),
    lists:foreach(
      fun(Id) ->
              error_logger:info_msg("Unsupervising dead child:  ~p~n", [Id]),
              supervisor:delete_child(?MODULE, Id)
      end, Dead),
    Rv.

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
