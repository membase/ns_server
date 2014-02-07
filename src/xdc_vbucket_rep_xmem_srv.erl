%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License"); you may not
%% use this file except in compliance with the License. You may obtain a copy of
%% the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
%% License for the specific language governing permissions and limitations under
%% the License.

%% This module is responsible for communication to remote memcached process for
%% individual vbucket. It gets tarted and stopped by the vbucket replicator module


-module(xdc_vbucket_rep_xmem_srv).
-behaviour(gen_server).

%% public functions
-export([start_link/4]).
-export([init/1, terminate/2, code_change/3]).
-export([handle_call/3, handle_cast/2, handle_info/2]).

-export([connect/2, stop/1]).
-export([find_missing/2, flush_docs/2]).

-export([format_status/2, get_worker/1]).

-include("xdc_replicator.hrl").
-include("remote_clusters_info.hrl").


%% -------------------------------------------------------------------------- %%
%% ---                         public functions                           --- %%
%% -------------------------------------------------------------------------- %%
start_link(Vb, RemoteXMem, ParentVbRep, Options) ->
    %% prepare parameters to start xmem server process
    NumWorkers = proplists:get_value(xmem_worker, Options),
    ConnectionTimeout = proplists:get_value(connection_timeout, Options),

    Args = {Vb, RemoteXMem, ParentVbRep, NumWorkers, ConnectionTimeout},
    {ok, Pid} = gen_server:start_link(?MODULE, Args, []),
    {ok, Pid}.

%% gen_server behavior callback functions
init({Vb, RemoteXMem, ParentVbRep, NumWorkers, ConnectionTimeout}) ->
    process_flag(trap_exit, true),
    %% signal to self to initialize
    {ok, AllWorkers} = start_worker_process(Vb, NumWorkers, ConnectionTimeout),
    {T1, T2, T3} = now(),
    random:seed(T1, T2, T3),
    Errs = ringbuffer:new(?XDCR_ERROR_HISTORY),
    InitState = #xdc_vb_rep_xmem_srv_state{vb = Vb,
                                           parent_vb_rep = ParentVbRep,
                                           remote = RemoteXMem,
                                           statistics = #xdc_vb_rep_xmem_statistics{},
                                           pid_workers = AllWorkers,
                                           num_workers = NumWorkers,
                                           seed = {T1, T2, T3},
                                           error_reports = Errs},

    ?xdcr_debug("xmem server (vb: ~p, parent vb rep: ~p) initialized (remote ip: ~p, port: ~p, "
                "# of xmem workers: ~p)",
                [Vb, ParentVbRep,
                 RemoteXMem#xdc_rep_xmem_remote.ip,
                 RemoteXMem#xdc_rep_xmem_remote.port,
                 dict:size(AllWorkers)]),

    {ok, InitState}.

format_status(Opt, [PDict, State]) ->
    xdc_rep_utils:sanitize_status(Opt, PDict, State).

connect(Server, XMemRemote) ->
    gen_server:call(Server, {connect, XMemRemote}, infinity).

-spec get_worker(pid()) -> {pid(), boolean()}.
get_worker(Server) ->
    gen_server:call(Server, get_worker, infinity).

-spec stop(nil | pid()) -> ok.
stop(nil) ->
    ok;
stop(Server) ->
    gen_server:cast(Server, stop).

-spec find_missing(pid(), list()) -> {ok, list()} |
                                     {error, term()}.
find_missing(Server, IdRevs) ->
    gen_server:call(Server, {find_missing, IdRevs}, infinity).

-spec flush_docs(pid(), list()) ->  ok | {error, term()}.
flush_docs(Server, DocsList) ->
    gen_server:call(Server, {flush_docs, DocsList}, infinity).

handle_info({'EXIT',_Pid, normal}, St) ->
    {noreply, St};

handle_info({'EXIT',_Pid, Reason}, St) ->
    {stop, Reason, St}.

handle_call({connect, Remote}, {_Pid, _Tag},
            #xdc_vb_rep_xmem_srv_state{
                       pid_workers = Workers} = State) ->
    lists:foreach(
      fun ({_Id, Worker}) ->
              ok = xdc_vbucket_rep_xmem_worker:connect(Worker, Remote)
      end, dict:to_list(Workers)),

    NewState = State#xdc_vb_rep_xmem_srv_state{remote = Remote},
    {reply, ok, NewState};

handle_call({find_missing, IdRevs}, _From,
            #xdc_vb_rep_xmem_srv_state{vb = Vb, pid_workers = Workers} =  State) ->

    WorkerPid = load_balancer(Vb, Workers),
    TimeStart = now(),
    {ok, MissingIdRevs} =
        xdc_vbucket_rep_xmem_worker:find_missing_pipeline(WorkerPid, IdRevs),
    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    NumIdRevs = length(IdRevs),
    AvgLatency = TimeSpent div NumIdRevs,

    ?xdcr_trace("[xmem_srv for vb ~p]: out of ~p keys, we need to send ~p "
                "(worker: ~p, avg latency: ~p ms).",
                [Vb, NumIdRevs, length(MissingIdRevs), WorkerPid, AvgLatency]),

    {reply, {ok, MissingIdRevs}, State};

handle_call({flush_docs, DocsList}, _From,
            #xdc_vb_rep_xmem_srv_state{vb = Vb, pid_workers = Workers} = State) ->

    WorkerPid = load_balancer(Vb, Workers),
    TimeStart = now(),
    {ok, NumDocRepd, NumDocRejected} =
        xdc_vbucket_rep_xmem_worker:flush_docs_pipeline(WorkerPid, DocsList),
    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    AvgLatency = TimeSpent div length(DocsList),

    ?xdcr_trace("[xmem_srv for vb ~p]: out of total ~p docs, "
                "# of docs accepted by remote: ~p "
                "# of docs rejected by remote: ~p"
                "(worker: ~p,"
                "time spent in ms: ~p, avg latency per doc in ms: ~p)",
                [Vb, length(DocsList),
                 NumDocRepd, NumDocRejected,
                 WorkerPid, TimeSpent, AvgLatency]),

    {reply, ok, State};

handle_call(get_worker, _From,
            #xdc_vb_rep_xmem_srv_state{vb =  Vb,
                                       pid_workers = Workers} = State) ->
    {reply, load_balancer(Vb, Workers), State};

handle_call(stats, _From,
            #xdc_vb_rep_xmem_srv_state{} = State) ->
    Props = [],
    NewState = State,
    {reply, {ok, Props}, NewState};

handle_call(Msg, From, #xdc_vb_rep_xmem_srv_state{vb = Vb} = State) ->
    ?xdcr_error("[xmem_srv for vb ~p]: received unexpected call ~p from process ~p",
                [Vb, Msg, From]),
    {stop, {error, {unexpected_call, Msg, From}}, State}.

handle_cast(stop, #xdc_vb_rep_xmem_srv_state{vb = Vb} = State) ->
    %% let terminate() do the cleanup
    ?xdcr_debug("[xmem_srv for vb ~p]: receive stop, let terminate() clean up", [Vb]),
    {stop, normal, State};

handle_cast({report_error, Err}, #xdc_vb_rep_xmem_srv_state{error_reports = Errs} = State) ->
    {noreply, State#xdc_vb_rep_xmem_srv_state{error_reports = ringbuffer:add(Err, Errs)}};

handle_cast(Msg, #xdc_vb_rep_xmem_srv_state{vb = Vb} = State) ->
    ?xdcr_error("[xmem_srv for vb ~p]: received unexpected cast ~p", [Vb, Msg]),
    {stop, {error, {unexpected_cast, Msg}}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, State) when Reason == normal orelse Reason == shutdown ->
    terminate_cleanup(State);

terminate(Reason, #xdc_vb_rep_xmem_srv_state{vb = Vb, parent_vb_rep = Par} = State) ->

    report_error(Reason, Vb, Par),
    ?xdcr_error("[xmem_srv for vb ~p]: shutdown xmem server, error reported to parent ~p",
                [Vb, Par]),
    terminate_cleanup(State),
    ok.

terminate_cleanup(#xdc_vb_rep_xmem_srv_state{vb = Vb, pid_workers = Workers} = _State) ->
    %% close sock and shutdown each worker process
    {Gone, Shutdown} =
        lists:foldl(
          fun({_Id, WorkerPid}, {WorkersGone, WorkersShutdown}) ->
                  case process_info(WorkerPid) of
                      undefined ->
                          %% already gone
                          ?xdcr_debug("worker (pid: ~p) already gone", [WorkerPid]),
                          WorkersGone1 = lists:flatten([WorkerPid | WorkersGone]),
                          {WorkersGone1, WorkersShutdown};
                      _ ->
                          ok = xdc_vbucket_rep_xmem_worker:stop(WorkerPid),
                          WorkersShutdown1 = lists:flatten([WorkerPid | WorkersShutdown]),
                          {WorkersGone, WorkersShutdown1}
                  end
          end,
          {[], []},
          dict:to_list(Workers)),

    ?xdcr_debug("[xmem_srv for vb ~p]: worker process (~p) already gone, shutdown processes (~p)",
                [Vb, Gone, Shutdown]),

    ok.


%% -------------------------------------------------------------------------- %%
%% ---                  internal helper functions                         --- %%
%% -------------------------------------------------------------------------- %%
report_error(Err, _Vb, _Parent) when Err == normal orelse Err == shutdown ->
    ok;
report_error(Err, Vb, Parent) ->
    %% return raw erlang time to make it sortable
    RawTime = erlang:localtime(),
    Time = misc:iso_8601_fmt(RawTime),
    ErrorMsg = case Err of
                   {{error, {ErrorStat, _ErrorKeys}}, _State} ->
                       ?format_msg("parent vb replicator: ~p, "
                                   "xmem stats: ~s. Please see logs "
                                   "for state dump and complete list of error keys.",
                                   [Parent, ErrorStat]);
                   OtherErr ->
                       OtherErr
               end,

    String = iolist_to_binary(?format_msg("~s [XMem Srv] Error replicating vbucket ~p: ~p",
                                          [Time, Vb, ErrorMsg])),
    gen_server:cast(Parent, {report_error, {RawTime, String}}).


-spec start_worker_process(integer(), integer(), integer()) -> {ok, dict()}.
start_worker_process(Vb, NumWorkers, ConnectionTimeout) ->
    WorkerDict = dict:new(),
    AllWorkers = lists:foldl(
                   fun(Id, Acc) ->
                           {ok, Pid} = xdc_vbucket_rep_xmem_worker:start_link(Vb, Id, self(),
                                                                              ConnectionTimeout),
                           dict:store(Id, Pid, Acc)
                   end,
                   WorkerDict,
                   lists:seq(1, NumWorkers)),

    ?xdcr_debug("all xmem worker processes have started (vb: ~p, num of workers: ~p)",
                [Vb, dict:size(AllWorkers)]),
    {ok, AllWorkers}.

-spec load_balancer(integer(), dict()) -> pid().
load_balancer(Vb, Workers) ->
    NumWorkers = dict:size(Workers),
    Index = random:uniform(NumWorkers),
    {Id, WorkerPid} = lists:nth(Index, dict:to_list(Workers)),
    ?xdcr_trace("[xmem_srv for vb ~p]: pick up worker process (id: ~p, pid: ~p)", [Vb, Id, WorkerPid]),
    WorkerPid.
