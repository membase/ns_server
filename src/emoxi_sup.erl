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
