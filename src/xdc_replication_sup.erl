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

-export([start_replication/1, stop_replication/1, shutdown/0, get_replications/1]).

-export([init/1, start_link/0]).

-include("xdc_replicator.hrl").

start_link() ->
    supervisor:start_link({local,?MODULE}, ?MODULE, []).

start_replication(#rep{id = Id, source = SourceBucket} = Rep) ->
    Spec = {{SourceBucket, Id},
             {xdc_replication, start_link, [Rep]},
             permanent,
             100,
             worker,
             [xdc_replication]
            },
    supervisor:start_child(?MODULE, Spec).

-spec get_replications(binary()) -> [{_, pid()}].
get_replications(SourceBucket) ->
    [{Id, Pid}
     || {{Bucket, Id}, Pid, _, _} <- supervisor:which_children(?MODULE),
        Bucket =:= SourceBucket].


stop_replication(Id) ->
    lists:foreach(
        fun(Child) when element(2, element(1, Child)) == Id ->
                supervisor:terminate_child(?MODULE, element(1, Child)),
                ok = supervisor:delete_child(?MODULE, element(1, Child));
           (_) ->
                ok
        end,  supervisor:which_children(?MODULE)),
    ?xdcr_debug("all replications for DocId ~p have been stopped", [Id]),
    ok.


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
