-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

% TODO: Should these be parameterized, or configurable?

-define(TIMEOUT_AWAIT_OK,         100000). % 100 seconds.
-define(TIMEOUT_WORKER_GO,          1000). % 1 seconds.
-define(TIMEOUT_WORKER_INACTIVE, 1000000). % 1000 seconds.

% We have one MBox per Addr.
%
-record(mbox, {addr, pid, started}).

% A dict of all the currently active, alive mboxes.
-record(dmgr, {curr}).

%% API for downstream manager service.
%%
%% This module is unaware of pools or buckets.  It only knows of and
%% manages connections to individual downstream targets (or Addr/MBox
%% pairs).  For example, multiple buckets or pools in this erlang VM
%% might be sharing the downstream targets.  When a downstream dies,
%% all the higher level layers can learn of it via this module's
%% monitor/demonitor abstraction.

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop()       -> gen_server:stop(?MODULE).

monitor(Addr) ->
    case gen_server:call(?MODULE, {pid, Addr}) of
        {ok, MBoxPid} -> monitor_mbox(MBoxPid);
        Error         -> Error
    end.

demonitor(undefined)   -> ok;
demonitor(MonitorRefs) ->
    % TODO: Need to remove any DOWN messages that are already
    %       waiting in our/self()'s mailbox?
    lists:foreach(fun erlang:demonitor/1, MonitorRefs),
    ok.

send(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule) ->
    send(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule,
         self(), undefined).

send(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule,
     NotifyPid, NotifyData) ->
    Kind = mc_addr:kind(Addr),
    ResponseFun =
        fun (Head, Body) ->
            case ((not is_function(ResponseFilter)) orelse
                  (ResponseFilter(Head, Body))) of
                true  -> ResponseModule:send_response(Kind, Out,
                                                      Cmd, Head, Body);
                false -> false
            end
        end,
    case gen_server:call(?MODULE, {pid, Addr}) of
        {ok, MBoxPid} ->
            {ok, Monitor} = monitor_mbox(MBoxPid),
            MBoxPid ! {send, NotifyPid, NotifyData, ResponseFun,
                       kind_to_module(Kind), Cmd, CmdArgs},
            {ok, [Monitor]};
        _Error -> {error, []}
    end.

send_call(Addr, Op, NotifyPid, NotifyData,
          ResponseFun, CmdModule, Cmd, CmdArgs) ->
    gen_server:call(?MODULE,
                    {send, Addr, Op, NotifyPid, NotifyData,
                     ResponseFun, CmdModule, Cmd, CmdArgs}).

kind_to_module(ascii)  -> mc_client_ascii_ac;
kind_to_module(binary) -> mc_client_binary_ac.

% Accumulate results of send calls, useful with foldl.
accum(CallResult, {NumOks, AccMonitors}) ->
    case CallResult of
        {ok, Monitors} -> {NumOks + 1, Monitors ++ AccMonitors};
        {_,  Monitors} -> {NumOks, Monitors ++ AccMonitors}
    end.

await_ok(N) -> await_ok(undefined, N, 0).
await_ok(Prefix, N, Acc) when N > 0 ->
    % TODO: Decrementing N due to a DOWN might be incorrect
    % during edge/race conditions.
    % TODO: Need to match the MonitorRef's we get from 'DOWN' messages?
    receive
        {Prefix, {ok, _}}              -> await_ok(Prefix, N - 1, Acc + 1);
        {Prefix, {ok, _, _}}           -> await_ok(Prefix, N - 1, Acc + 1);
        {Prefix, _}                    -> await_ok(Prefix, N - 1, Acc);
        {'DOWN', _MonitorRef, _, _, _} -> await_ok(Prefix, N - 1, Acc)
    after ?TIMEOUT_AWAIT_OK ->
        % When we've waited too long, free up the caller.
        % TODO: Need to demonitor?
        Acc
    end;
await_ok(_, _, Acc) -> Acc.

%% gen_server implementation.

init([]) ->
    {ok, #dmgr{curr = dict:new()}}.

terminate(_Reason, _DMgr) -> ok.
code_change(_OldVn, DMgr, _Extra) -> {ok, DMgr}.

handle_info({'EXIT', ChildPid, Reason}, #dmgr{curr = Dict} = DMgr) ->
    ?debugVal({exit_downstream, ChildPid, Reason}),
    Dict2 = dict:filter(fun(_Addr, #mbox{pid = Pid}) ->
                            Pid =/= ChildPid
                        end,
                        Dict),
    {noreply, DMgr#dmgr{curr = Dict2}};

handle_info(_Info, DMgr) -> {noreply, DMgr}.

handle_cast(_Msg, DMgr) -> {noreply, DMgr}.

handle_call({pid, Addr}, _From, DMgr) ->
    case make_mbox(DMgr, Addr) of
        {ok, DMgr2, #mbox{pid = MBoxPid}} ->
            Reply = {ok, MBoxPid},
            {reply, Reply, DMgr2};
        Error ->
            {reply, Error, DMgr}
    end;

handle_call({send, Addr, Op, NotifyPid, NotifyData,
             ResponseFun, CmdModule, Cmd, CmdArgs}, _From, DMgr) ->
    case make_mbox(DMgr, Addr) of
        {ok, DMgr2, #mbox{pid = MBoxPid}} ->
            MBoxPid ! {Op, NotifyPid, NotifyData, ResponseFun,
                       CmdModule, Cmd, CmdArgs},
            {reply, ok, DMgr2};
        Error ->
            {reply, Error, DMgr}
    end.

% ---------------------------------------------------

monitor_mbox(MBoxPid) ->
    {ok, erlang:monitor(process, MBoxPid)}.

% Retrieves or starts an mbox for an Addr.
make_mbox(#dmgr{curr = Dict} = DMgr, Addr) ->
    case dict:find(Addr, Dict) of
        {ok, MBox} ->
            {ok, DMgr, MBox};
        error ->
            case start_mbox(Addr) of
                {ok, MBox} -> Dict2 = dict:store(Addr, MBox, Dict),
                              {ok, #dmgr{curr = Dict2}, MBox};
                Error      -> Error
            end
    end.

start_mbox(Addr) ->
    case start_link(Addr) of
        {ok, Pid} -> {ok, #mbox{addr = Addr, pid = Pid,
                                started = erlang:now()}};
        Error     -> Error
    end.

start_link(Addr) ->
    Location = mc_addr:location(Addr),
    [Host, Port | _] = string:tokens(Location, ":"),
    PortNum = list_to_integer(Port),
    % We connect here, instead of in the worker, to
    % allow faster error detection and avoid the races we'd have
    % otherwise between ?MODULE:monitor() and ?MODULE:send().
    case gen_tcp:connect(Host, PortNum,
                         [binary, {packet, 0}, {active, false}]) of
        {ok, Sock} ->
            % TODO: Auth.
            % TODO: Bucket selection.
            % TODO: Protocol capability test (binary or ascii).
            process_flag(trap_exit, true),
            WorkerPid = spawn_link(?MODULE, worker, [Addr, Sock]),
            gen_tcp:controlling_process(Sock, WorkerPid),
            WorkerPid ! go,
            {ok, WorkerPid};
        Error -> Error
    end.

%% Child/worker process implementation, where we have one child/worker
%% process per downstream Addr or MBox.  Note, this can one day be a
%% child/worker in a supervision tree.

worker(Addr, Sock) ->
    % The go delay allows the spawner to setup gen_tcp:controller_process.
    receive
        go ->
            case mc_addr:kind(Addr) of
                ascii  -> loop(Addr, Sock);
                binary ->
                    case mc_client_binary:auth(Sock, mc_addr:auth(Addr)) of
                        ok   -> loop(Addr, Sock);
                        _Err -> ns_log:log(mcd_0001, "auth failed")
                    end
            end
    after ?TIMEOUT_WORKER_GO -> stop
    end.

loop(Addr, Sock) ->
    inet:setopts(Sock, [{active, once}]),
    receive
        {send, NotifyPid, NotifyData, ResponseFun,
               CmdModule, Cmd, CmdArgs} ->
            inet:setopts(Sock, [{active, false}]),
            RV = CmdModule:cmd(Cmd, Sock, ResponseFun, CmdArgs),
            notify(NotifyPid, NotifyData, RV),
            case RV of
                {ok, _}    -> loop(Addr, Sock);
                {ok, _, _} -> loop(Addr, Sock);
                _Error     -> gen_tcp:close(Sock)
            end;
        {tcp_closed, Sock} -> ok
    after ?TIMEOUT_WORKER_INACTIVE ->
        gen_tcp:close(Sock),
        stop
    end.

notify(P, D, V) when is_pid(P) -> P ! {D, V};
notify(_, _, _)                -> ok.

group_by(Keys, KeyFunc) ->
    group_by(Keys, KeyFunc, dict:new()).

group_by([Key | Rest], KeyFunc, Dict) ->
    G = KeyFunc(Key),
    group_by(Rest, KeyFunc,
             dict:update(G, fun (V) -> [Key | V] end, [Key], Dict));
group_by([], _KeyFunc, Dict) ->
    lists:map(fun ({G, Val}) -> {G, lists:reverse(Val)} end,
              dict:to_list(Dict)).

% ---------------------------------------------------

% For testing...
%
mbox_test() ->
    D1 = dict:new(),
    M1 = #dmgr{curr = D1},
    A1 = mc_addr:local(ascii),
    {ok, M2, B1} = make_mbox(M1, A1),
    ?assertMatch({ok, M2, B1}, make_mbox(M2, A1)).

element2({_X, Y}) -> Y.

group_by_edge_test() ->
    ?assertMatch([],
                 group_by([],
                          fun element2/1)),
    ?assertMatch([{1, [{a, 1}]}],
                 group_by([{a, 1}],
                          fun element2/1)),
    ok.

group_by_simple_test() ->
    ?assertMatch([{1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {b, 1}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {b, 1}, {c, 2}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {c, 2}, {b, 1}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{c, 2}, {a, 1}, {b, 1}],
                          fun element2/1)),
    ok.
