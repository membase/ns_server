% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(xdc_replication_sup).
-behaviour(supervisor).

-export([start_replication/1, stop_replication/1, update_replication/2,
         shutdown/0,
         get_replications/0, get_replications/1,
         all_local_replication_infos/0,
         stop_all_replications/0]).

-export([init/1, start_link/0]).

-include("xdc_replicator.hrl").

start_link() ->
    ?xdcr_info("start XDCR bucket replicator supervisor..."),
    ets:delete_all_objects(xdcr_stats),
    supervisor:start_link({local,?MODULE}, ?MODULE, []).

start_replication(#rep{id = Id, source = SourceBucket} = Rep) ->
    Spec = {{SourceBucket, Id},
             {xdc_replication, start_link, [Rep]},
             permanent,
             100,
             worker,
             [xdc_replication]
            },
    ?xdcr_info("start bucket replicator using spec: ~p.", [Spec]),
    xdc_rep_utils:init_replication_stats(Id),
    RV = supervisor:start_child(?MODULE, Spec),
    ok = element(1, RV).

-spec get_replications() -> [{Bucket :: binary(), Id :: binary(), pid()}].
get_replications() ->
    [{Bucket, Id, Pid}
     || {{Bucket, Id}, Pid, _, _} <- supervisor:which_children(?MODULE)].

-spec get_replications(binary()) -> [{_, pid()}].
get_replications(SourceBucket) ->
    [{Id, Pid}
     || {{Bucket, Id}, Pid, _, _} <- supervisor:which_children(?MODULE),
        Bucket =:= SourceBucket].

-spec all_local_replication_infos() -> [{Id :: binary(), [{atom(), _}], [{erlang:timestamp(), ErrorMsg :: binary()}]}].
all_local_replication_infos() ->
    [{Id, Stats, Errors}
     || {{_Bucket, Id}, Pid, _, _} <- supervisor:which_children(?MODULE),
        Stats <- try xdc_replication:stats(Pid) of
                     {ok, X} -> [X]
                 catch T:E ->
                         ?xdcr_debug("Ignoring error getting possibly stale stats:~n~p", [{T,E,erlang:get_stacktrace()}]),
                         []
                 end,
        Errors <- try xdc_replication:latest_errors(Pid) of
                      {ok, AnErrors} ->
                          [AnErrors]
                  catch T:E ->
                          ?xdcr_debug("Ignoring error getting possibly stale errors:~n~p", [{T,E,erlang:get_stacktrace()}])
                  end].

stop_replication(Id) ->
    [stop_child(Child) || {{_, RepId}, _, _, _} = Child <- supervisor:which_children(?MODULE),
                          RepId =:= Id],
    ?xdcr_debug("all replications for DocId ~p have been stopped", [Id]),
    ok.

stop_all_replications() ->
    [stop_child(Child) || Child <- supervisor:which_children(?MODULE)],
    ?xdcr_debug("all replications have been stopped"),
    ok.

stop_child({{_, Id} = ChildId, _, _, _} = Child) ->
    ?xdcr_debug("Found matching child to stop: ~p", [Child]),
    ok = supervisor:terminate_child(?MODULE, ChildId),
    xdc_rep_utils:cleanup_replication_stats(Id),
    ok = supervisor:delete_child(?MODULE, ChildId).

update_replication(RepId, RepDoc) ->
    case [Child || {_, Id, _} = Child <- get_replications(), Id =:= RepId] of
        [] ->
            start_replication(RepDoc);
        [{Bucket, RepId, Pid}] ->
            R = xdc_replication:update_replication(Pid, RepDoc),
            case R of
                restart_needed ->
                    ok = supervisor:terminate_child(?MODULE, {Bucket, RepId}),
                    ok = supervisor:delete_child(?MODULE, {Bucket, RepId}),
                    start_replication(RepDoc);
                ok ->
                    {ok, Pid}
            end
    end.

shutdown() ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid ->
            MonRef = erlang:monitor(process, Pid),
            exit(Pid, shutdown),
            receive {'DOWN', MonRef, _Type, _Object, _Info} ->
                ok
            end
    end.

%%=============================================================================
%% supervisor callbacks
%%=============================================================================

init([]) ->
    {ok, {{one_for_one, 3, 10}, []}}.

%%=============================================================================
%% internal functions
%%=============================================================================
