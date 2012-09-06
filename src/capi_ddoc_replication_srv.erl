%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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

%% Maintains design document replication between the <BucketName>/master
%% vbuckets (CouchDB databases) of all cluster nodes.

-module(capi_ddoc_replication_srv).
-include("couch_db.hrl").
-include("ns_common.hrl").

-behaviour(gen_server).

-export([start_link/1, update_doc/2,
         foreach_doc/2, fetch_ddoc_ids/1,
         full_live_ddocs/1,
         sorted_full_live_ddocs/1,
         foreach_live_ddoc_id/2]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {bucket,
                server_name,
                remote_nodes = [],
                local_docs = [] :: [#doc{}]}).

update_doc(Bucket, Doc) ->
    gen_server:call(server_name(Bucket),
                    {interactive_update, Doc}, infinity).

-spec fetch_ddoc_ids(bucket_name() | binary()) -> [binary()].
fetch_ddoc_ids(Bucket) ->
    Pairs = foreach_live_ddoc_id(Bucket, fun (_) -> ok end),
    erlang:element(1, lists:unzip(Pairs)).

-spec foreach_live_ddoc_id(bucket_name() | binary(),
                           fun ((binary()) -> any())) -> [{binary(), any()}].
foreach_live_ddoc_id(Bucket, Fun) ->
    Ref = make_ref(),
    RVs = foreach_doc(
            Bucket,
            fun (Doc) ->
                    case Doc of
                        #doc{deleted = true} ->
                            Ref;
                        _ ->
                            Fun(Doc#doc.id)
                    end
            end),
    [Pair || {_Id, V} = Pair <- RVs,
             V =/= Ref].

full_live_ddocs(Bucket) ->
    Ref = make_ref(),
    RVs = foreach_doc(
            Bucket,
            fun (Doc) ->
                    case Doc of
                        #doc{deleted = true} ->
                            Ref;
                        _ ->
                            Doc
                    end
            end),
    [V || {_Id, V} <- RVs,
          V =/= Ref].

sorted_full_live_ddocs(Bucket) ->
    lists:keysort(#doc.id, full_live_ddocs(Bucket)).



start_link(Bucket) ->
    gen_server:start_link({local, server_name(Bucket)},
                          ?MODULE, [Bucket], []).


-spec foreach_doc(bucket_name() | binary(),
                   fun ((#doc{}) -> any())) -> [{binary(), any()}].
foreach_doc(Bucket, Fun) ->
    gen_server:call(server_name(Bucket), {foreach_doc, Fun}, infinity).

%% Callbacks

init([Bucket]) ->
    Self = self(),

    %% Update myself whenever the config changes (rebalance)
    ns_pubsub:subscribe_link(
      ns_config_events,
      fun (_, _) -> Self ! replicate_newnodes_docs end,
      empty),

    {ok, Db} = open_local_db(Bucket),
    Docs = try
               {ok, ADocs} = couch_db:get_design_docs(Db, deleted_also),
               ADocs
           after
               ok = couch_db:close(Db)
           end,
    %% anytime we disconnect or reconnect, force a replicate event.
    ns_pubsub:subscribe_link(
      ns_node_disco_events,
      fun ({ns_node_disco_events, _Old, _New}, _) ->
              Self ! replicate_newnodes_docs
      end,
      empty),
    Self ! replicate_newnodes_docs,

    %% Explicitly ask all available nodes to send their documents to us
    ServerName = server_name(Bucket),
    [{ServerName, N} ! replicate_newnodes_docs ||
        N <- get_remote_nodes(Bucket)],

    {ok, #state{bucket = Bucket,
                server_name = ServerName,
                local_docs=Docs}}.


handle_call({interactive_update, #doc{id=Id}=Doc}, _From, State) ->
    #state{local_docs=Docs}=State,
    Rand = crypto:rand_uniform(0, 16#100000000),
    RandBin = <<Rand:32/integer>>,
    NewRev = case lists:keyfind(Id, #doc.id, Docs) of
                 false ->
                     {1, RandBin};
                 #doc{rev = {Pos, _DiskRev}} ->
                     {Pos + 1, RandBin}
             end,
    NewDoc = Doc#doc{rev=NewRev},
    try
        ?log_debug("Writing interactively saved ddoc ~p", [Doc]),
        SavedDocState = save_doc(NewDoc, State),
        replicate_change(SavedDocState, NewDoc),
        {reply, ok, SavedDocState}
    catch throw:{invalid_design_doc, _} = Error ->
            ?log_debug("Document validation failed: ~p", [Error]),
            {reply, Error, State}
    end;
handle_call({foreach_doc, Fun}, _From, #state{local_docs = Docs} = State) ->
    Res = [{Id, (catch Fun(Doc))} || #doc{id = Id} = Doc <- Docs],
    {reply, Res, State}.

replicate_change(#state{server_name = ServerName,
                        remote_nodes=Nodes}, Doc) ->
    [replicate_change_to_node(ServerName, Node, Doc) || Node <- Nodes],
    ok.

save_doc(#doc{id = Id} = Doc,
         #state{bucket=Bucket, local_docs=Docs}=State) ->
    {ok, Db} = open_local_db(Bucket),
    try
        ok = couch_db:update_doc(Db, Doc)
    after
        ok = couch_db:close(Db)
    end,
    State#state{local_docs = lists:keystore(Id, #doc.id, Docs, Doc)}.

handle_cast({replicated_update, #doc{id=Id, rev=Rev}=Doc}, State) ->
    %% this is replicated from another node in the cluster. We only accept it
    %% if it doesn't exist or the rev is higher than what we have.
    #state{local_docs=Docs} = State,
    Proceed = case lists:keyfind(Id, #doc.id, Docs) of
                  false ->
                      true;
                  #doc{rev = DiskRev} when Rev > DiskRev ->
                      true;
                  _ ->
                      false
              end,
    if Proceed ->
            ?log_debug("Writing replicated ddoc ~p", [Doc]),
            {noreply, save_doc(Doc, State)};
       true ->
            {noreply, State}
    end.


handle_info({'DOWN', _Ref, _Type, {Server, RemoteNode}, Error},
            #state{remote_nodes = RemoteNodes} = State) ->
    ?log_warning("Remote server node ~p process down: ~p",
                 [{Server, RemoteNode}, Error]),
    {noreply, State#state{remote_nodes=RemoteNodes -- [RemoteNode]}};
handle_info(replicate_newnodes_docs, State) ->
    ?log_debug("doing replicate_newnodes_docs"),
    {noreply, replicate_newnodes_docs(State)}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


replicate_newnodes_docs(State) ->
    #state{bucket=Bucket,
           server_name = ServerName,
           remote_nodes=OldNodes,
           local_docs = Docs} = State,
    AllNodes = get_remote_nodes(Bucket),
    NewNodes = AllNodes -- OldNodes,
    case NewNodes of
        [] ->
            ok;
        _ ->
            [monitor(process, {ServerName, Node}) || Node <- NewNodes],
            [replicate_change_to_node(ServerName, S, D)
             || S <- NewNodes,
                D <- Docs]
    end,
    State#state{remote_nodes=AllNodes}.

replicate_change_to_node(ServerName, Node, Doc) ->
    ?log_debug("Sending ~s to ~s", [Doc#doc.id, Node]),
    gen_server:cast({ServerName, Node}, {replicated_update, Doc}).


server_name(Bucket) when is_binary(Bucket) ->
    server_name(?b2l(Bucket));
server_name(Bucket) ->
    list_to_atom(?MODULE_STRING ++ "-" ++ Bucket).


get_remote_nodes(Bucket) ->
    case ns_bucket:get_bucket(Bucket) of
        {ok, Conf} ->
            proplists:get_value(servers, Conf) -- [node()];
        not_present ->
            []
    end.

open_local_db(Bucket) ->
    MasterVBucket = iolist_to_binary([Bucket, <<"/master">>]),
    case couch_db:open(MasterVBucket, []) of
        {ok, Db} ->
            {ok, Db};
        {not_found, _} ->
            couch_db:create(MasterVBucket, [])
    end.
