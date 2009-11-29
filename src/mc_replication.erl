-module(mc_replication).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(replicator, {
          id,
          request,
          monitors = [],
          notify_pid,
          notify_data,
          replica_addrs,
          replica_min,
          replica_next = 1,
          received_err = 0,
          received_ok  = 0,
          sent_err     = [], % List of {Addr, Err} tuples.
          sent_ok      = [], % List of Addrs that had send successes.
          responses    = []  % List of {Addr, []}.
         }).

-record(rmgr, {
          curr % A dict of the currently active replicators.
         }).

start() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
stop()  -> gen_server:stop(?MODULE).

% When the replication Policy is undefined, we can skip
% straight to the mc_downstream:send().
send([Addr], Out, Cmd, CmdArgs,
     ResponseFilter, ResponseModule, undefined) ->
    mc_downstream:send(Addr, Out, Cmd, CmdArgs,
                       ResponseFilter, ResponseModule);

send(Addrs, Out, Cmd, CmdArgs,
     ResponseFilter, ResponseModule, Policy) ->
    gen_server:call(?MODULE,
                    {replicate, Addrs, Out, Cmd, CmdArgs,
                     ResponseFilter, ResponseModule, Policy}).

%% gen_server implementation.

init([]) -> {ok, #rmgr{curr = dict:new()}}.
terminate(_Reason, _RMgr) -> ok.
code_change(_OldVn, RMgr, _Extra) -> {ok, RMgr}.
handle_cast(_Msg, RMgr) -> {noreply, RMgr}.

handle_call({replicate, Addrs, _Out, _Cmd, _CmdArgs,
             _ResponseFilter, _ResponseModule, _Policy} = Request,
            {NotifyPid, _}, #rmgr{curr = Replicators} = RMgr) ->
    % TODO: Use Policy.
    Replicator = create_replicator(Request, NotifyPid, undefined, Addrs),
    Replicator2 = send_cycle(Replicator),
    Replicators2 = dict:store(Replicator2#replicator.id,
                              Replicator2,
                              Replicators),
    {reply, {ok, []}, RMgr#rmgr{curr = Replicators2}}.

handle_info({Id, RV}, #rmgr{curr = Replicators} = RMgr) ->
    % Invoked when a downstream is done with a request/response.
    case dict:find(Id, Replicators) of
        {ok, #replicator{notify_pid = NotifyPid,
                         notify_data = NotifyData}} ->
            notify(NotifyPid, NotifyData, RV),
            Replicators2 = dict:erase(Id, Replicators),
            {noreply, RMgr#rmgr{curr = Replicators2}};
        error ->
            {noreply, RMgr}
    end;

handle_info({'DOWN', Monitor, _, _, _} = Msg,
            #rmgr{curr = Replicators} = RMgr) ->
    % Invoked when a monitored downstream has died.
    Replicators2 =
        dict:filter(fun (_Id, #replicator{notify_pid = NotifyPid,
                                          notify_data = NotifyData,
                                          monitors = Monitors}) ->
                        case lists:member(Monitor, Monitors) of
                            true  -> notify(NotifyPid, NotifyData, Msg),
                                     true;
                            false -> false
                        end
                    end,
                    Replicators),
    {noreply, RMgr#rmgr{curr = Replicators2}}.

notify(P, D, V) when is_pid(P) -> P ! {D, V};
notify(_, _, _)                -> ok.

create_replicator(Request, NotifyPid, NotifyData, Addrs) ->
    Id = make_ref(),
    #replicator{id = Id,
                request = Request,
                notify_pid = NotifyPid,
                notify_data = NotifyData,
                replica_addrs = Addrs,
                replica_min = 1}.

send_cycle(#replicator{id = Id,
                       request = Request,
                       monitors = Monitors} = Replicator) ->
    {replicate, Addrs, Out, Cmd, CmdArgs,
     ResponseFilter, ResponseModule, _Policy} = Request,
    Monitors2 =
        lists:flatmap(
          fun (Addr) ->
              {ok, AddrMonitors} =
                  mc_downstream:send(Addr, Out, Cmd, CmdArgs,
                                     ResponseFilter, ResponseModule,
                                     self(), Id),
              AddrMonitors
          end,
          Addrs),
    Replicator#replicator{monitors = Monitors2 ++ Monitors}.

