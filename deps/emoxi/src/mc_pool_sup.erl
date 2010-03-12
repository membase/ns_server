% Copyright (c) 2010, NorthScale, Inc
% All rights reserved.

-module(mc_pool_sup).

-behaviour(supervisor).

-export([start_link/1, init/1, current_children/1,
         reconfig/1, reconfig/2, reconfig_nodes/2]).

-include_lib("eunit/include/eunit.hrl").

start_link(Name) ->
    ServerName = name_to_server_name(Name),
    supervisor:start_link({local, ServerName}, ?MODULE, Name).

% mc_pull_sup children are dynamic...
%
%     mc_pool {gen_server} keeps buckets map & state
%       permanent so that REST kvcache pathway works
%     mc_accept {spawn_link} 11211| might not start if port conflict)
%       session-loop_in {spawn_link} mc_pool-default
%         session-loop_out {spawn_link}}
%       ...
%       session-loop_in {spawn_link} mc_pool-default
%         session-loop_out {spawn_link}}

init(Name) ->
    case ns_config:search_prop(ns_config:get(), pools, Name) of
        undefined  -> ns_log:log(?MODULE, 0001, "missing pool config: ~p",
                                 [Name]),
                      {error, einval};
        PoolConfig -> child_specs(Name, PoolConfig)
    end.

child_specs(Name, PoolConfig) ->
    Children = [child_spec_pool(Name, PoolConfig),
                child_spec_accept(Name, PoolConfig)],
    {ok, {{rest_for_one, 3, 10}, Children}}.

child_spec_pool(Name, _PoolConfig) ->
    {{mc_pool, Name}, {mc_pool, start_link, [Name]},
     permanent, 10, worker, []}.

child_spec_accept(Name, PoolConfig) ->
    AddrStr = proplists:get_value(address, PoolConfig, "0.0.0.0"),
    PortNum =
        case os:getenv("MC_ACCEPT_PORT_" ++ Name) of
            false ->
                case proplists:get_value({node, node(), port},
                                         PoolConfig, false) of
                    false -> proplists:get_value(port, PoolConfig, 11211);
                    P     -> P
                end;
            X -> Y = list_to_integer(X),
                 error_logger:info_msg(
                   "MC_ACCEPT_PORT_~p override: ~p~n",
                   [Name, Y]),
                 Y
        end,
    Env = {mc_server_detect,
           mc_server_detect,
           {mc_pool, Name}},
    Args = [PortNum, AddrStr, Env],
    {{mc_accept, Args}, {mc_accept, start_link, Args},
     permanent, 10, worker, []}.

reconfig(Name) ->
    case ns_config:search_prop(ns_config:get(), pools, Name) of
        undefined  -> ns_log:log(?MODULE, 0002, "stopping missing pool: ~p",
                                 [Name]),
                      emoxi_sup:stop_pool(Name);
        PoolConfig -> reconfig(Name, PoolConfig)
    end.

reconfig(Name, PoolConfig) ->
    ServerName = name_to_server_name(Name),
    CurrentChildren = current_children(Name),
    error_logger:info_msg("Reconfiguring ~p from within ~p~n",
                          [Name, CurrentChildren]),
    lists:foreach(
      fun({{mc_accept, _} = Spec, undefined, _, _}) ->
              ns_log:log(?MODULE, 0003, "reconfig accept start ~p", [Name]),
              supervisor:terminate_child(ServerName, Spec),
              ok = supervisor:delete_child(ServerName, Spec),
              supervisor:start_child(ServerName,
                                     child_spec_accept(Name, PoolConfig)),
              ok;
         ({{mc_accept, CurrArgs} = Spec, _Pid, _, _}) ->
              WantSpec = child_spec_accept(Name, PoolConfig),
              {_, {_, _, WantArgs}, _, _, _, _} = WantSpec,
              error_logger:info_msg("Wanted ~p, got ~p~n", [WantArgs, CurrArgs]),
              case CurrArgs =:= WantArgs of
                  true  -> ok;
                  false ->
                      ns_log:log(?MODULE, 0004, "reconfig accept change ~p",
                                 [Name]),
                      error_logger:info_msg("~p reconfig ~p -> ~p~n",
                                            [?MODULE, CurrArgs, WantArgs]),
                      supervisor:terminate_child(ServerName, Spec),
                      ok = supervisor:delete_child(ServerName, Spec),
                      supervisor:start_child(ServerName, WantSpec)
              end;
         ({{mc_pool, N}, Pid, _, _}) when N =:= Name ->
              mc_pool:reconfig(Pid, Name);
         (_) -> ok % We don't care about non-matching children.
      end,
      CurrentChildren).

reconfig_nodes(Name, _) ->
    Nodes = ns_node_disco:nodes_actual_proper(),
    CurrentChildren = current_children(Name),
    lists:foreach(
      fun({{mc_pool, N}, Pid, _, _}) when N =:= Name ->
              mc_pool:reconfig(Pid, Name);
         (_) -> ok % We don't care about non-matching children.
      end,
      CurrentChildren).

current_children(Name) ->
    % Children will look like...
    %   [{mc_pool,<0.77.0>,worker,[_]},
    %    {mc_accept,<0.78.0>,worker,[_]}]
    %
    ServerName = name_to_server_name(Name),
    supervisor:which_children(ServerName).

name_to_server_name(Name) ->
    list_to_atom(atom_to_list(?MODULE) ++ "-" ++ Name).

