%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
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
-module(ns_vbm_sup).

-behavior(supervisor).

-include("ns_common.hrl").

%% identifier of ns_vbm_sup childs in supervisors. NOTE: vbuckets
%% field is sorted. We could use ordsets::ordset() type, but we also
%% want to underline that vbuckets field is never empty.
-record(new_child_id, {vbuckets::[vbucket_id(), ...],
                       src_node::node()}).

%% API
-export([start_link/1, init/1]).

%% Callbacks
-export([server_name/1, supervisor_node/2,
         make_replicator/2, replicator_nodes/2, replicator_vbuckets/1,
         build_child_spec/2, get_children/1]).

-export([perform_vbucket_filter_change/6]).

%%
%% API
%%
start_link(Bucket) ->
    supervisor:start_link({local, server_name(Bucket)}, ?MODULE, []).

init([]) ->
    {ok, {{one_for_one,
           misc:get_env_default(max_r, 3),
           misc:get_env_default(max_t, 10)},
          []}}.


%%
%% Callbacks
%%
-spec server_name(bucket_name()) -> atom().
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING "-" ++ Bucket).

-spec supervisor_node(node(), node()) -> node().
supervisor_node(_SrcNode, DstNode) ->
    DstNode.

-spec make_replicator(node(), [vbucket_id(), ...]) -> #new_child_id{}.
make_replicator(SrcNode, VBuckets) ->
    #new_child_id{vbuckets=VBuckets, src_node=SrcNode}.

-spec replicator_nodes(node(), #new_child_id{}) -> {node(), node()}.
replicator_nodes(SupervisorNode, #new_child_id{src_node=Node}) ->
    {Node, SupervisorNode}.

-spec replicator_vbuckets(#new_child_id{}) -> [vbucket_id(), ...].
replicator_vbuckets(#new_child_id{vbuckets=VBuckets}) ->
    VBuckets.

mk_old_state_retriever(Id) ->
    %% this function's closure will be kept in supervisor, so I want
    %% it to reference as few stuff as possible thus separate closure maker
    fun () ->
            case ns_process_registry:lookup_pid(vbucket_filter_changes_registry, Id) of
                missing -> undefined;
                TxnPid ->
                    case (catch gen_server:call(TxnPid, get_old_state, infinity)) of
                        {ok, OldState} ->
                            ?log_info("Got vbucket filter change old state. "
                                      "Proceeding vbucket filter change operation"),
                            OldState;
                        TxnCrap ->
                            ?log_info("Getting old state for vbucket "
                                      "change operation failed:~n~p", [TxnCrap]),
                            undefined
                    end
            end
    end.

perform_vbucket_filter_change(Bucket,
                              OldChildId, NewChildId,
                              InitialArgs,
                              StartVBFilterChangeMFA,
                              Server) ->
    try
        do_perform_vbucket_filter_change(Bucket,
                                         OldChildId, NewChildId,
                                         InitialArgs,
                                         StartVBFilterChangeMFA,
                                         Server)
    catch error:{unexpected_reason, upstream_conn_is_down} ->
            %% I don't want {unexpected_reason, _} which is
            %% implementation detail of misc:executing_on_new_process
            %% to leak out of this code
            erlang:error(upstream_conn_is_down)
    end.

do_perform_vbucket_filter_change(Bucket,
                                 OldChildId, NewChildId,
                                 InitialArgs,
                                 StartVBFilterChangeMFA,
                                 Server) ->
    RegistryId = {Bucket, NewChildId, erlang:make_ref()},
    Args = ebucketmigrator_srv:add_args_option(InitialArgs,
                                               old_state_retriever,
                                               mk_old_state_retriever(RegistryId)),

    NewVBuckets = ebucketmigrator_srv:get_args_option(Args, vbuckets),
    true = NewVBuckets =/= undefined,

    Childs = supervisor:which_children(Server),
    MaybeThePid = [Pid || {Id, Pid, _, _} <- Childs,
                          Id =:= OldChildId],
    NewChildSpec = build_child_spec(NewChildId, Args),
    case MaybeThePid of
        [ThePid] ->
            misc:executing_on_new_process(
              fun () ->
                      ns_process_registry:register_pid(vbucket_filter_changes_registry,
                                                       RegistryId, self()),
                      ?log_debug("Registered myself under id:~p~nArgs:~p",
                                 [RegistryId, Args]),

                      erlang:link(ThePid),
                      ?log_debug("Linked myself to old ebucketmigrator ~p",
                                 [ThePid]),

                      {ok, OldState} = start_vbucket_filter_change(ThePid, StartVBFilterChangeMFA),
                      ?log_debug("Got old state from previous ebucketmigrator: ~p",
                                 [ThePid]),

                      erlang:process_flag(trap_exit, true),
                      ok = supervisor:terminate_child(Server, OldChildId),
                      Me = self(),
                      proc_lib:spawn_link(
                        fun () ->
                                {ok, Pid} = supervisor:start_child(Server, NewChildSpec),
                                Me ! {done, Pid}
                        end),
                      perform_vbucket_filter_change_loop(ThePid, OldState, false)
              end);
        [] ->
            no_child
    end.

start_vbucket_filter_change(ThePid, {M, F, A}) ->
    Args = [ThePid | A],
    erlang:apply(M, F, Args).

perform_vbucket_filter_change_loop(ThePid, OldState, SentAlready) ->
    receive
        {'EXIT', ThePid, shutdown} ->
            perform_vbucket_filter_change_loop(ThePid, OldState, SentAlready);
        {'EXIT', _From, _Reason} = ExitMsg ->
            ?log_error("Got unexpected exit signal in "
                       "vbucket change txn body: ~p", [ExitMsg]),
            exit({txn_crashed, ExitMsg});
        {done, RV} ->
            RV;
        {'$gen_call', {Pid, _} = From, get_old_state} ->
            case SentAlready of
                false ->
                    ?log_debug("Sent old state to new instance"),
                    ebucketmigrator_srv:set_controlling_process(OldState, Pid),
                    gen_server:reply(From, {ok, OldState});
                true ->
                    gen_server:reply(From, refused)
            end,
            perform_vbucket_filter_change_loop(ThePid, OldState, true)
    end.

build_child_spec(ChildId, Args) ->
    {ChildId,
     {ebucketmigrator_srv, start_link, Args},
     temporary, 60000, worker, [ebucketmigrator_srv]}.

-spec get_children(bucket_name()) -> list() | not_running.
get_children(Bucket) ->
    try supervisor:which_children(server_name(Bucket)) of
        RawKids ->
            [Id || {Id, _Child, _Type, _Mods} <- RawKids]
    catch exit:{noproc, _} ->
            not_running
    end.
