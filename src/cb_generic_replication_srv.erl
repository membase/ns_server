%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
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

-module(cb_generic_replication_srv).

-behaviour(gen_server).

-include("couch_replicator.hrl").
-include("couch_api_wrap.hrl").
-include("couch_db.hrl").
-include("ns_common.hrl").

-export([start_link/2, start_link/3, force_update/1, force_update/2]).

-export([behaviour_info/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).


-record(state, {module, module_state, opts,
                servers=[], ref_to_server, local_url, retry_timer}).

-define(RETRY_AFTER, 5000).

behaviour_info(callbacks) ->
    [{init, 1},
     {server_name, 1}, {get_servers, 1}, {remote_url, 2}, {local_url, 1}].


start_link(Mod, Args) ->
    start_link(Mod, Args, default_opts()).

start_link(Mod, Args, Opts) ->
    gen_server:start_link({local, server_name(Mod, Args)},
                          ?MODULE, [Mod, Args, Opts], []).

force_update(Pid) ->
    Pid ! update.

force_update(Mod, Args) ->
    force_update(server_name(Mod, Args)).

init([Mod, Args, Opts]) ->
    case Mod:init(Args) of
        {ok, ModState} ->
            State = #state{module=Mod,
                           module_state=ModState,
                           servers=[],
                           ref_to_server=dict:new(),
                           opts=Opts,
                           local_url=local_url(Mod, ModState)},
            self() ! start_replication,
            erlang:process_flag(trap_exit, true),
            {ok, State};
        Error ->
            Error
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_replication, State) ->
    {noreply, start_replication(State)};

handle_info(update, State) ->
    {noreply, update(State)};

handle_info({'DOWN', Ref, process, _Pid, Reason}, State)
  when Reason =:= normal orelse Reason =:= shutdown ->
    {noreply, remove_done_replication(Ref, State)};
handle_info({'DOWN', Ref, process, _Pid, Reason}, State) ->
    ?log_info("Replication slave crashed with reason: ~p", [Reason]),
    {noreply, update(remove_done_replication(Ref, State))}.

terminate(Reason, State) when Reason =:= normal orelse Reason =:= shutdown ->
    stop_replication(State),
    ok;
terminate(Reason, State) ->
    stop_replication(State),
    %% Sometimes starting replication fails because of vbucket
    %% databases creation race or (potentially) because of remote node
    %% unavailability. When this process repeatedly fails our
    %% supervisor ends up dying due to
    %% max_restart_intensity_reached. Because we'll change our local
    %% ddocs replication mechanism lets simply delay death a-la
    %% supervisor_cushion to prevent that.
    ?log_info("Delaying death during unexpected termination: ~p~n", [Reason]),
    timer:sleep(3000),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% Auxiliary functions
start_replication(State) ->
    update(State#state{servers=[]}).

stop_replication(#state{servers=Servers} = State) ->
    [stop_server_replication(Srv, State) || Srv <- Servers],
    stop_retry_timer(State#state{servers=[]}).

update(#state{module=Mod, module_state=ModState} = State) ->
    update(State, Mod:get_servers(ModState)).

update(#state{servers=Servers} = State, NewServers) ->
    {ToStartServers, ToStopServers} = difference(Servers, NewServers),
    ToKeep = Servers -- (ToStartServers ++ ToStopServers),

    {Started, Failed, State1} =
        lists:foldl(
          fun (Srv, {AccStarted, AccFailed, AccState}) ->
                  case start_server_replication(Srv, AccState) of
                      {ok, AccState1}  ->
                          {[Srv | AccStarted], AccFailed, AccState1};
                      {Error, AccState1} ->
                          ?log_error("Failed to start replication to ~p: ~p",
                                     [Srv, Error]),
                          {AccStarted, [Srv | AccFailed], AccState1}
                  end
          end, {[], [], State}, ToStartServers),

    [stop_server_replication(Srv, State1) || Srv <- ToStopServers],

    State2 = State1#state{servers=ToKeep ++ Started},
    case Failed of
        [] ->
            State2;
        _Other ->
            retry(State2)
    end.

difference(List1, List2) ->
    {List2 -- List1, List1 -- List2}.

stop_retry_timer(#state{retry_timer=undefined} = State) ->
    State;
stop_retry_timer(#state{retry_timer=Timer} = State) ->
    {ok, cancel} = timer:cancel(Timer),
    State#state{retry_timer=undefined}.

retry(#state{retry_timer=undefined} = State) ->
    {ok, Timer} = timer:send_after(?RETRY_AFTER, update),
    State#state{retry_timer=Timer};
retry(State) ->
    retry(stop_retry_timer(State)).

start_server_replication(Node, #state{ref_to_server=RefToServer} = State) ->
    Opts = build_replication_struct(remote_url(Node, State),
                                    local_url(State), State),
    case couch_replicator:async_replicate(Opts) of
        {ok, Pid} ->
            Ref = erlang:monitor(process, Pid),
            State1 =
                State#state{ref_to_server=dict:store(Ref, Node, RefToServer)},
            {ok, State1};
        Error ->
            {Error, State}
    end.

stop_server_replication(Node, State) ->
    Opts = build_replication_struct(remote_url(Node, State),
                                    local_url(State), State),
    %% ref is removed when corresponding DOWN message is delivered
    {ok, _Res} = couch_replicator:cancel_replication(Opts#rep.id).

default_opts() ->
    [{<<"continuous">>, true},
     {<<"worker_processes">>, 1},
     {<<"http_connections">>, 10}
    ].

build_replication_struct(Source, Target, #state{opts=Opts} = _State) ->
    {ok, Replication} =
        couch_replicator_utils:parse_rep_doc(
          {[{<<"source">>, Source},
            {<<"target">>, Target}
            | Opts]},
          #user_ctx{roles = [<<"_admin">>]}),
    Replication.

local_url(Mod, ModState) ->
    Mod:local_url(ModState).

local_url(#state{local_url=LocalUrl} = _State) ->
    LocalUrl.

remote_url(Node, #state{module=Mod, module_state=ModState} = _State) ->
    Mod:remote_url(Node, ModState).

server_name(Mod, Args) ->
    Mod:server_name(Args).

remove_done_replication(Ref, #state{ref_to_server=RefToServer,
                                    servers=Servers} = State) ->
    Server = dict:fetch(Ref, RefToServer),
    State#state{servers=Servers -- [Server],
                ref_to_server=dict:erase(Ref, RefToServer)}.
