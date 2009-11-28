-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(mbox, {addr, pid, history}).
-record(dmgr, {curr % A dict of all the currently active, alive mboxes.
               }).

%% API for downstream manager service.
%%
%% This module is unaware of pools, buckets, only connections to
%% individual downstream targets (or Addr/MBox pairs).  For example,
%% multiple buckets or pools in this erlang VM might be sharing the
%% downstream targets.  When a downstream dies, all the higher level
%% layers can learn of it via the monitor/demonitor abstraction.

start() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop() -> gen_server:stop(?MODULE).

monitor(Addr) ->
    gen_server:call(?MODULE, {monitor, Addr}).

demonitor(MonitorRefs) ->
    lists:foreach(fun erlang:demonitor/1, MonitorRefs).

send(Addr, Op, NotifyPid, NotifyData, ResponseFun,
     CmdModule, Cmd, CmdArgs) ->
    gen_server:call(?MODULE,
                    {send, Addr, Op, NotifyPid, NotifyData,
                     ResponseFun, CmdModule, Cmd, CmdArgs}).

forward(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule) ->
    forward(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule,
            self(), undefined).

forward(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule,
        NotifyPid, NotifyData) ->
    Kind = mc_addr:kind(Addr),
    ResponseFun =
        fun (Head, Body) ->
            case ((not is_function(ResponseFilter)) orelse
                  (ResponseFilter(Head, Body))) of
                true  -> apply(ResponseModule, send_response,
                               [Kind, Out, Cmd, Head, Body]);
                false -> false
            end
        end,
    {ok, Monitor} = monitor(Addr),
    case send(Addr, fwd, NotifyPid, NotifyData, ResponseFun,
              kind_to_module(Kind), Cmd, CmdArgs) of
        ok -> {ok, Monitor};
        _  -> {error, Monitor}
    end.

kind_to_module(ascii)  -> mc_client_ascii_ac;
kind_to_module(binary) -> mc_client_binary_ac.

% Accumulate results of forward during a foldl.
accum(A2xForwardResult, {NumOks, Monitors}) ->
    case A2xForwardResult of
        {ok, Monitor} -> {NumOks + 1, [Monitor | Monitors]};
        {_,  Monitor} -> {NumOks, [Monitor | Monitors]}
    end.

await_ok(N) -> await_ok(undefined, N, 0).
await_ok(NotifyData, N, Acc) when N > 0 ->
    % TODO: Decrementing N due to a DOWN might be incorrect
    % during edge/race conditions.
    receive
        {NotifyData, {ok, _}}    -> await_ok(NotifyData, N - 1, Acc + 1);
        {NotifyData, {ok, _, _}} -> await_ok(NotifyData, N - 1, Acc + 1);
        {'DOWN', _MonitorRef, _, _, _}  -> await_ok(NotifyData, N - 1, Acc);
        Unexpected -> ?debugVal(Unexpected),
                      exit({error, Unexpected})
    end;
await_ok(_, _, Acc) -> Acc.

%% gen_server implementation.

init([]) -> {ok, #dmgr{curr = dict:new()}}.
terminate(_Reason, _DMgr) -> ok.
code_change(_OldVn, DMgr, _Extra) -> {ok, DMgr}.
handle_info(_Info, DMgr) -> {noreply, DMgr}.
handle_cast(_Msg, DMgr) -> {noreply, DMgr}.

handle_call({monitor, Addr}, _From, DMgr) ->
    {DMgr2, #mbox{pid = Pid}} = make_mbox(DMgr, Addr),
    Reply = {ok, erlang:monitor(process, Pid)},
    {reply, Reply, DMgr2};

handle_call({send, Addr, Op, NotifyPid, NotifyData,
             ResponseFun, CmdModule, Cmd, CmdArgs}, _From, DMgr) ->
    {DMgr2, #mbox{pid = Pid}} = make_mbox(DMgr, Addr),
    Pid ! {Op, NotifyPid, NotifyData, ResponseFun,
           CmdModule, Cmd, CmdArgs},
    {reply, ok, DMgr2}.

% ---------------------------------------------------

% Retrieves or creates an mbox for an Addr.
make_mbox(#dmgr{curr = Dict} = DMgr, Addr) ->
    case dict:find(Addr, Dict) of
        {ok, MBox} -> {DMgr, MBox};
        _ -> MBox = create_mbox(Addr),
             Dict2 = dict:store(Addr, MBox, Dict),
             {#dmgr{curr = Dict2}, MBox}
    end.

create_mbox(Addr) ->
    {ok, Pid} = start_link(Addr),
    #mbox{addr = Addr, pid = Pid, history = []}.

%% Child/worker process implementation, where we have one child/worker
%% process per downstream Addr or MBox.  Note, this can be a
%% child/worker in a supervision tree.

start_link(Addr) ->
    Location = mc_addr:location(Addr),
    [Host, Port] = string:tokens(Location, ":"),
    PortNum = list_to_integer(Port),
    {ok, Sock} = gen_tcp:connect(Host, PortNum,
                                 [binary, {packet, 0}, {active, false}]),
    % TODO: Auth.
    % TODO: Bucket selection.
    % TODO: Protocol capability test (binary or ascii).
    {ok, spawn_link(?MODULE, loop, [Addr, Sock])}.

loop(Addr, Sock) ->
    receive
        {fwd, NotifyPid, NotifyData, ResponseFun,
              CmdModule, Cmd, CmdArgs} ->
            RV = apply(CmdModule, cmd, [Cmd, Sock, ResponseFun, CmdArgs]),
            notify(NotifyPid, NotifyData, RV),
            case RV of
                {ok, _}    -> loop(Addr, Sock);
                {ok, _, _} -> loop(Addr, Sock);
                Error      -> gen_tcp:close(Sock),
                              exit({error, Error})
            end;
        close ->
            gen_tcp:close(Sock)
    end.

notify(P, D, V) when is_pid(P) -> P ! {D, V};
notify(_, _, _) -> ok.

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
    {M2, B1} = make_mbox(M1, A1),
    ?assertMatch({M2, B1}, make_mbox(M2, A1)).

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
