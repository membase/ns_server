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

-export([behaviour_info/1]).

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

-export([conditional/2, conditional/4]).

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

-type pred_fun()      :: fun ((State :: term()) -> false | term()).
-type timeout_fun()   :: fun ((State :: term()) -> handler_result()).
-type cond_body_fun() :: fun ((PredResult :: term(), State :: term()) ->
                                     handler_result()).

-record(condition, { id    :: reference(),
                     timer :: misc:timer(),
                     pred  :: pred_fun(),

                     on_timeout :: timeout_fun(),
                     on_success :: cond_body_fun() }).

%% Callbacks (all optional)

%% Inherited from gen_server
%%
%% -callback init(Args :: term()) ->
%%     {ok, State :: term()} | {ok, State :: term(), timeout() | hibernate} |
%%     {stop, Reason :: term()} | ignore.
%% -callback handle_call(Request :: term(), From :: {pid(), Tag :: term()},
%%                       State :: term()) ->
%%     {reply, Reply :: term(), NewState :: term()} |
%%     {reply, Reply :: term(), NewState :: term(), timeout() | hibernate} |
%%     {noreply, NewState :: term()} |
%%     {noreply, NewState :: term(), timeout() | hibernate} |
%%     {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
%%     {stop, Reason :: term(), NewState :: term()}.
%% -callback handle_cast(Request :: term(), State :: term()) ->
%%     {noreply, NewState :: term()} |
%%     {noreply, NewState :: term(), timeout() | hibernate} |
%%     {stop, Reason :: term(), NewState :: term()}.
%% -callback handle_info(Info :: timeout | term(), State :: term()) ->
%%     {noreply, NewState :: term()} |
%%     {noreply, NewState :: term(), timeout() | hibernate} |
%%     {stop, Reason :: term(), NewState :: term()}.
%% -callback terminate(Reason :: (normal | shutdown | {shutdown, term()} |
%%                                term()),
%%                     State :: term()) ->
%%     term().
%% -callback code_change(OldVsn :: (term() | {down, term()}), State :: term(),
%%                       Extra :: term()) ->
%%     {ok, NewState :: term()} | {error, Reason :: term()}.

%% gen_server2 specific optional callbacks
%%
%% -callback handle_job_death(Queue :: term(), Name :: term(), Reason :: term()) ->
%%     {continue, Reply :: term()} |
%%     {stop, Reason :: term()}.

%% With all callbacks being optional, erlang doesn't understand anymore that
%% this is a behavior. Having a dummy behaviour_info/1 exported fixes that.
behaviour_info(callbacks) ->
    [];
behaviour_info(_Other) ->
    undefined.

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

conditional(Pred, OnSuccess) ->
    add_condition(Pred, OnSuccess, infinity, undefined).

conditional(Pred, OnSuccess, Timeout, OnTimeout) ->
    true = is_integer(Timeout),
    add_condition(Pred, OnSuccess, Timeout, OnTimeout).

%% gen_server callbacks
init([Module, Args]) ->
    set_state(module, Module),

    Callbacks = [{init, 1},
                 {handle_call, 3},
                 {handle_cast, 2},
                 {handle_info, 2},
                 {terminate, 2},
                 {code_change, 3},
                 {handle_job_death, 3}],
    lists:foreach(fun ({F, A}) ->
                          set_state({have_callback, F},
                                    erlang:function_exported(Module, F, A))
                  end, Callbacks),

    call_callback(init, [Args], {ok, undefined}).

handle_call(Request, From, State) ->
    check_conditions(call_handle_call(Request, From, State)).

call_handle_call(Request, From, State) ->
    call_callback(handle_call, [Request, From, State],
                  {stop, {unexpected_call, Request, From, State}, State}).

handle_cast(Msg, State) ->
    check_conditions(call_handle_cast(Msg, State)).

call_handle_cast(Msg, State) ->
    call_callback(handle_cast, [Msg, State],
                  {stop, {unexpected_cast, Msg, State}, State}).

handle_info(Info, State) ->
    check_conditions(do_handle_info(Info, State)).

do_handle_info({'$gen_server2', condition_expired, Id}, State) ->
    handle_condition_expired(Id, State);
do_handle_info({'$gen_server2', job_result, Queue, Result}, State) ->
    handle_job_result(Queue, Result, State);
do_handle_info({'DOWN', MRef, process, _Pid, Reason} = Info, State) ->
    case get_active_job(#async_job.mref, MRef) of
        {ok, Job} ->
            case call_handle_job_death(Job, Reason) of
                {continue, Reply} ->
                    handle_job_result(Job#async_job.queue, Reply, State);
                {stop, StopReason} ->
                    {stop, StopReason, State}
            end;
        not_found ->
            call_handle_info(Info, State)
    end;
do_handle_info(Info, State) ->
    call_handle_info(Info, State).

call_handle_info(Info, State) ->
    call_callback(handle_info, [Info, State],
                  {stop, {unexpected_info, Info, State}, State}).

terminate(Reason, State) ->
    call_callback(terminate, [Reason, State], ok),
    async:abort_many(lists:map(_#async_job.pid, get_active_jobs())).

code_change(OldVsn, State, Extra) ->
    check_conditions(call_callback(code_change,
                                   [OldVsn, State, Extra], {ok, State})).

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

call_handle_job_death(#async_job{queue = Queue, name = Name} = Job, Reason) ->
    call_callback(handle_job_death,
                  [Queue, Name, Reason],
                  {stop, {async_job_died, Job, Reason}}).

handle_job_result(Queue, Result, State) ->
    {ok, Job} = take_active_job(Queue),
    erlang:demonitor(Job#async_job.mref, [flush]),

    %% reuse the result for all following jobs with the same name on the same
    %% queue
    MoreJobs = dequeue_same_name_jobs(Job#async_job.name, Queue),
    maybe_start_job(Queue),

    chain_handle_results([Job | MoreJobs], Result, State).

add_condition(Pred, OnSuccess, Timeout, OnTimeout) ->
    Id = make_ref(),

    Timer0 = misc:create_timer({'$gen_server2', condition_expired, Id}),
    Timer  =
        case Timeout of
            infinity ->
                true = (OnTimeout =:= undefined),
                Timer0;
            _ when is_integer(Timeout) ->
                true = is_function(OnTimeout),
                misc:arm_timer(Timeout, Timer0)
        end,

    Cond =
        #condition{id         = Id,
                   timer      = Timer,
                   pred       = Pred,
                   on_timeout = OnTimeout,
                   on_success = OnSuccess},

    update_state(conditions, [Cond | _], []).

take_condition(Id) ->
    case lists:keytake(Id, #condition.id, get_state(conditions)) of
        {value, Cond, Rest} ->
            case Rest of
                [] ->
                    del_state(conditions);
                _ ->
                    set_state(conditions, Rest)
            end,

            {ok, Cond};
        false ->
            not_found
    end.

handle_condition_expired(Id, State) ->
    {ok, Cond} = take_condition(Id),
    (Cond#condition.on_timeout)(State).

check_conditions(Reply) ->
    case should_check_conditions(Reply) of
        true ->
            Ix    = state_ix(Reply),
            State = element(Ix, Reply),

            case check_conditions_with_state(State) of
                {noreply, NewState} ->
                    setelement(Ix, Reply, NewState);
                {stop, _, _} = Stop ->
                    Stop
            end;
        false ->
            Reply
    end.

should_check_conditions(Reply) ->
    should_check_conditions_by_tag(element(1, Reply)).

should_check_conditions_by_tag(stop) ->
    false;
should_check_conditions_by_tag(error) ->
    false;
should_check_conditions_by_tag(_) ->
    true.

state_ix(Reply) ->
    Tag = element(1, Reply),
    case Tag of
        reply ->
            3;
        noreply ->
            2;
        ok ->
            2
    end.

check_conditions_with_state(State) ->
    {Satisfied, Rest} =
        lists:foldr(fun (Cond, {AccSatisfied, AccRest}) ->
                            case (Cond#condition.pred)(State) of
                                false ->
                                    {AccSatisfied, [Cond | AccRest]};
                                Other ->
                                    misc:cancel_timer(Cond#condition.timer),
                                    {[{Cond, Other} | AccSatisfied], AccRest}
                            end
                    end, {[], []}, get_state(conditions, [])),

    set_state(conditions, Rest),
    chain_condition_bodies(Satisfied, State).

chain_condition_bodies([], State) ->
    {noreply, State};
chain_condition_bodies([{Cond, PredResult} | Rest], State) ->
    case (Cond#condition.on_success)(PredResult, State) of
        {noreply, NewState} ->
            chain_condition_bodies(Rest, NewState);
        {stop, _, _} = Stop ->
            Stop
    end.

call_callback(Name, Args, OnNotExported) ->
    case get_state({have_callback, Name}) of
        true ->
            erlang:apply(get_module(), Name, Args);
        false ->
            OnNotExported
    end.
