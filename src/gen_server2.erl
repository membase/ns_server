%% @author Couchbase <info@couchbase.com>
%% @copyright 2017 Couchbase, Inc.
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
-module(gen_server2).

-behavior(gen_server).

%% Standard gen_server APIs
-export([start/3, start/4]).
-export([start_link/3, start_link/4]).
-export([call/2, call/3]).
-export([cast/2, reply/2]).
-export([abcast/2, abcast/3]).
-export([multi_call/2, multi_call/3, multi_call/4]).
-export([enter_loop/3, enter_loop/4, enter_loop/5]).

%% gen_server2-specific APIs
-export([async_job/2, async_job/3, async_job/4]).
-export([abort_queue/1, abort_queue/3]).
-export([get_active_queues/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("cut.hrl").
-include("ns_common.hrl").

-type handler_result() :: {noreply, NewState :: any()} |
                          {stop, Reason :: any(), NewState :: any()}.

-type body_fun()          :: fun  (() -> Result :: any()).
-type handle_result_fun() :: fun ((Result :: any(), State  :: any()) ->
                                         handler_result()).

-record(async_job, { body          :: body_fun(),
                     handle_result :: handle_result_fun(),
                     queue         :: term(),
                     name          :: term(),

                     pid  :: undefined | pid(),
                     mref :: undefined | reference() }).

-callback init(Args :: term()) ->
    {ok, State :: term()} | {ok, State :: term(), timeout() | hibernate} |
    {stop, Reason :: term()} | ignore.
-callback handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                      State :: term()) ->
    {reply, Reply :: term(), NewState :: term()} |
    {reply, Reply :: term(), NewState :: term(), timeout() | hibernate} |
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
    {stop, Reason :: term(), NewState :: term()}.
-callback handle_cast(Request :: term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: term()}.
-callback handle_info(Info :: timeout | term(), State :: term()) ->
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), timeout() | hibernate} |
    {stop, Reason :: term(), NewState :: term()}.
-callback terminate(Reason :: (normal | shutdown | {shutdown, term()} |
                               term()),
                    State :: term()) ->
    term().
-callback code_change(OldVsn :: (term() | {down, term()}), State :: term(),
                      Extra :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

%% Standard gen_server APIs
start(Module, Args, Options) ->
    gen_server:start(?MODULE, [Module, Args], Options).

start(ServerName, Module, Args, Options) ->
    gen_server:start(ServerName, ?MODULE, [Module, Args], Options).

start_link(Module, Args, Options) ->
    gen_server:start_link(?MODULE, [Module, Args], Options).

start_link(ServerName, Module, Args, Options) ->
    gen_server:start_link(ServerName, ?MODULE, [Module, Args], Options).

call(Name, Request) ->
    gen_server:call(Name, Request).

call(Name, Request, Timeout) ->
    gen_server:call(Name, Request, Timeout).

cast(Name, Request) ->
    gen_server:cast(Name, Request).

reply(From, Reply) ->
    gen_server:reply(From, Reply).

abcast(Name, Request) ->
    gen_server:abcast(Name, Request).

abcast(Nodes, Name, Request) ->
    gen_server:abcast(Nodes, Name, Request).

multi_call(Name, Req) ->
    gen_server:multi_call(Name, Req).

multi_call(Nodes, Name, Req) ->
    gen_server:multi_call(Nodes, Name, Req).

multi_call(Nodes, Name, Req, Timeout) ->
    gen_server:multi_call(Nodes, Name, Req, Timeout).

enter_loop(Mod, Options, State) ->
    gen_server:enter_loop(Mod, Options, State).

enter_loop(Mod, Options, State, TimeoutOrServerName) ->
    gen_server:enter_loop(Mod, Options, State, TimeoutOrServerName).

enter_loop(Mod, Options, State, ServerName, Timeout) ->
    gen_server:enter_loop(Mod, Options, State, ServerName, Timeout).

%% gen_server2-specific APIs
async_job(Body, HandleResult) ->
    Ref = make_ref(),
    async_job(Ref, Ref, Body, HandleResult).

async_job(Queue, Body, HandleResult) ->
    async_job(Queue, make_ref(), Body, HandleResult).

async_job(Queue, Name, Body, HandleResult) ->
    enqueue_job(Queue, Name, Body, HandleResult),
    maybe_start_job(Queue),
    Queue.

abort_queue(Queue) ->
    _ = abort_jobs(Queue),
    ok.

abort_queue(Queue, AbortMarker, State) ->
    Jobs = abort_jobs(Queue),
    lists:foreach(
      fun (Job) ->
              %% assuming that aborted jobs can't modify the state
              {noreply, State} =
                  (Job#async_job.handle_result)(AbortMarker, State)
      end, Jobs).

get_active_queues() ->
    lists:map(_#async_job.queue, get_active_jobs()).

%% gen_server callbacks
init([Module, Args]) ->
    set_state(module, Module),
    Module:init(Args).

handle_call(Request, From, State) ->
    (get_module()):handle_call(Request, From, State).

handle_cast(Msg, State) ->
    (get_module()):handle_cast(Msg, State).

handle_info({'$gen_server2', job_result, Queue, Result}, State) ->
    {ok, Job} = take_active_job(Queue),
    erlang:demonitor(Job#async_job.mref, [flush]),

    %% reuse the result for all following jobs with the same name on the same
    %% queue
    MoreJobs = dequeue_same_name_jobs(Job#async_job.name, Queue),
    maybe_start_job(Queue),

    chain_handle_results([Job | MoreJobs], Result, State);
handle_info({'DOWN', MRef, process, _Pid, _Reason} = Info, State) ->
    case get_active_job(#async_job.mref, MRef) of
        {ok, Job} ->
            {stop, {async_job_died, Job, Info}, State};
        not_found ->
            (get_module()):handle_info(Info, State)
    end;
handle_info(Info, State) ->
    (get_module()):handle_info(Info, State).

terminate(Reason, State) ->
    (get_module()):terminate(Reason, State),
    async:abort_many(lists:map(_#async_job.pid, get_active_jobs())).

code_change(OldVsn, State, Extra) ->
    (get_module()):code_change(OldVsn, State, Extra).

%% internal
del_state(Key) ->
    erlang:erase({'$gen_server2', Key}).

set_state(Key, Value) ->
    erlang:put({'$gen_server2', Key}, Value).

get_state(Key) ->
    get_state(Key, undefined).

get_state(Key, Default) ->
    case erlang:get({'$gen_server2', Key}) of
        undefined ->
            Default;
        Value ->
            Value
    end.

update_state(Key, Fun) ->
    Value = get_state(Key),
    true  = (Value =/= undefined),

    set_state(Key, Fun(Value)).

update_state(Key, Fun, Default) ->
    set_state(Key, Fun(get_state(Key, Default))).

get_module() ->
    get_state(module).

get_active_jobs() ->
    get_state(active_jobs, []).

get_active_job(Queue) ->
    get_active_job(#async_job.queue, Queue).

get_active_job(Key, Value) ->
    case lists:keyfind(Value, Key, get_active_jobs()) of
        false ->
            not_found;
        Job ->
            {ok, Job}
    end.

set_active_job(Queue, Job) ->
    not_found = get_active_job(Queue),
    update_state(active_jobs, [Job | _], []).

remove_active_job(Queue) ->
    update_state(active_jobs, lists:keydelete(Queue, #async_job.queue, _)).

take_active_job(Queue) ->
    case get_active_job(Queue) of
        {ok, Job} ->
            remove_active_job(Queue),
            {ok, Job};
        not_found ->
            not_found
    end.

enqueue_job(Queue, Name, Body, HandleResult) ->
    Job = #async_job{body          = Body,
                     handle_result = HandleResult,
                     queue         = Queue,
                     name          = Name},

    update_state({queue, Queue},
                 queue:in(Job, _),
                 queue:new()).

set_queue(Queue, Value) ->
    case queue:is_empty(Value) of
        true ->
            del_state({queue, Queue});
        false ->
            set_state({queue, Queue}, Value)
    end.

dequeue_job(Queue) ->
    case get_state({queue, Queue}) of
        undefined ->
            empty;
        Q ->
            true = queue:is_queue(Q),
            {{value, Job}, NewQ} = queue:out(Q),
            set_queue(Queue, NewQ),

            {ok, Job}
    end.

dequeue_same_name_jobs(Name, Queue) ->
    Jobs = get_state({queue, Queue}, queue:new()),

    {Matching, Rest} = out_while(?cut(_#async_job.name =:= Name), Jobs),
    set_queue(Queue, Rest),
    queue:to_list(Matching).

out_while(Pred, Q) ->
    out_while(Pred, Q, queue:new()).

out_while(Pred, Q, AccQ) ->
    case queue:out(Q) of
        {empty, _} ->
            {AccQ, Q};
        {{value, V}, NewQ} ->
            case Pred(V) of
                true ->
                    out_while(Pred, NewQ, queue:in(V, AccQ));
                false ->
                    {AccQ, Q}
            end
    end.

maybe_start_job(Queue) ->
    case get_active_job(Queue) of
        not_found ->
            case dequeue_job(Queue) of
                {ok, Job} ->
                    start_job(Queue, Job);
                empty ->
                    ok
            end;
        _ ->
            ok
    end.

start_job(Queue, #async_job{body = Body} = Job) ->
    Self = self(),
    {Pid, MRef} = async:perform(
                    fun () ->
                            Self ! {'$gen_server2', job_result, Queue, Body()}
                    end),

    set_active_job(Queue, Job#async_job{pid = Pid, mref = MRef}).

chain_handle_results([], _Result, State) ->
    {noreply, State};
chain_handle_results([Job | Rest], Result, State) ->
    case (Job#async_job.handle_result)(Result, State) of
        {noreply, NewState} ->
            chain_handle_results(Rest, Result, NewState);
        {stop, _, _} = Stop ->
            Stop
    end.

abort_jobs(Queue) ->
    case take_active_job(Queue) of
        {ok, Job} ->
            erlang:demonitor(Job#async_job.mref, [flush]),
            async:abort(Job#async_job.pid),
            ?flush({'$gen_server2', job_result, Queue, _}),

            Waiting = get_state({queue, Queue}, queue:new()),
            del_state({queue, Queue}),
            [Job | queue:to_list(Waiting)];
        not_found ->
            []
    end.
