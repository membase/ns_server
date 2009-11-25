-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(mbox, {addr, pid, history}).
-record(dmgr, {curr % A dict of all the currently active, alive mboxes.
               }).

%% API for downstream manager service.

start() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop() -> gen_server:stop(?MODULE).

monitor(Addr) ->
    gen_server:call(?MODULE, {monitor, Addr}).

demonitor(MonitorRefs) ->
    lists:foreach(fun erlang:demonitor/1, MonitorRefs).

send(Addr, Op, NotifyPid, ResponseFun, CmdModule, Cmd, CmdArgs) ->
    gen_server:call(?MODULE,
                    {send, Addr, Op, NotifyPid,
                     ResponseFun, CmdModule, Cmd, CmdArgs}).

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
handle_call({send, Addr, Op, NotifyPid,
             ResponseFun, CmdModule, Cmd, CmdArgs}, _From, DMgr) ->
    {DMgr2, #mbox{pid = Pid}} = make_mbox(DMgr, Addr),
    Pid ! {Op, NotifyPid, ResponseFun, CmdModule, Cmd, CmdArgs},
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
        {fwd, NotifyPid, ResponseFun,
              CmdModule, Cmd, CmdArgs} ->
            RV = apply(CmdModule, cmd, [Cmd, Sock, ResponseFun, CmdArgs]),
            notify(NotifyPid, RV),
            case RV of
                {ok, _}    -> loop(Addr, Sock);
                {ok, _, _} -> loop(Addr, Sock);
                Error      -> gen_tcp:close(Sock),
                              exit({error, Error})
            end;
        close ->
            gen_tcp:close(Sock)
    end.

notify(P, V) when is_pid(P) -> P ! V;
notify(_, _) -> ok.

% ---------------------------------------------------

% For testing...
%
mbox_test() ->
    D1 = dict:new(),
    M1 = #dmgr{curr = D1},
    A1 = mc_addr:local(),
    {M2, B1} = make_mbox(M1, A1),
    ?assertMatch({M2, B1}, make_mbox(M2, A1)).

