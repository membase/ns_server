-module(mc_downstream).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(mbox, {addr, pid, history}).

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

init([]) -> {ok, dict:new()}.
terminate(_Reason, _Dict) -> ok.
code_change(_OldVsn, Dict, _Extra) -> {ok, Dict}.
handle_info(_Info, Dict) -> {noreply, Dict}.
handle_cast(_Msg, Dict) -> {noreply, Dict}.

handle_call({monitor, Addr}, _From, Dict) ->
    {Dict2, #mbox{pid = Pid}} = make_mbox(Dict, Addr),
    Reply = {ok, erlang:monitor(process, Pid)},
    {reply, Reply, Dict2};
handle_call({send, Addr, Op, NotifyPid,
             ResponseFun, CmdModule, Cmd, CmdArgs}, _From, Dict) ->
    {Dict2, #mbox{pid = Pid}} = make_mbox(Dict, Addr),
    Pid ! {Op, NotifyPid, ResponseFun, CmdModule, Cmd, CmdArgs},
    {reply, ok, Dict2}.

% ---------------------------------------------------

% Retrieves or creates an mbox for an Addr.
make_mbox(Dict, Addr) ->
    case dict:find(Addr, Dict) of
        {ok, MBox} -> {Dict, MBox};
        _ -> MBox = create_mbox(Addr),
             Dict2 = dict:store(Addr, MBox, Dict),
             {Dict2, MBox}
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
main() ->
    {mc_server_ascii_proxy:main(), start()}.
