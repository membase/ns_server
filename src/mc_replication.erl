-module(mc_replication).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

-record(replicator, {
          id,
          request,
          notify_pid,
          notify_data,
          sent_ok,          % # of successful sends.
          monitors,         % List of Monitor from mc_downstream:monitor().
          received_ok  = 0,
          received_err = 0,
          responses    = [] % List of {Addr, Response}.
         }).

-record(rmgr, {
          curr % A dict of the currently active replicators.
         }).

-record(request, {
          addrs,            % List of Addr, one for each replica.
          addrs_len,        % To save on repeated length(addrs).
          out,
          cmd,
          cmd_args,
          response_filter,
          response_module,
          received_ok_min   % # of received_ok before notifying requestor.
         }).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

% When the replication Config is undefined and we have just one Addr,
% we can skip straight to the mc_downstream:send().
send([Addr], Out, Cmd, CmdArgs,
     ResponseFilter, ResponseModule, undefined) ->
    mc_downstream:send(Addr, Out, Cmd, CmdArgs,
                       ResponseFilter, ResponseModule).

% send(Addrs, Out, Cmd, CmdArgs,
%      ResponseFilter, ResponseModule, ReceivedOkMin) ->
%     gen_server:call(?MODULE,
%                     {replicate,
%                      #request{addrs     = Addrs,
%                               addrs_len = length(Addrs),
%                               out = Out,
%                               cmd = Cmd,
%                               cmd_args = CmdArgs,
%                               response_filter = ResponseFilter,
%                               response_module = ResponseModule,
%                               received_ok_min = ReceivedOkMin}}).

%% Callbacks from mc_downstream.

send_response(Kind, {Id, Addr}, Cmd, Head, Body) ->
    gen_server:cast(?MODULE,
                    {response, Id, Addr, {response,
                                          Kind, Cmd, Head, Body}}).

%% gen_server implementation.

init([]) -> {ok, #rmgr{curr = dict:new()}}.
terminate(_Reason, _RMgr) -> ok.
code_change(_OldVn, RMgr, _Extra) -> {ok, RMgr}.

handle_call({replicate,
             #request{addrs = Addrs,
                      cmd = Cmd,
                      cmd_args = CmdArgs,
                      response_filter = ResponseFilter} = Request},
            {NotifyPid, _} = _From,
            #rmgr{curr = Replicators} = RMgr) ->
    ?debugVal({replicate, Request}),
    Id = make_ref(),
    {SentOk, Monitors} =
        lists:foldl(
          fun (Addr, Acc) ->
              % Redefining the Out to {Id, Addr} when we call
              % mc_downstream:send() so we can match result
              % notifications with the right replicator.  Also, we
              % provide ourselves as the ResponseModule so that we can
              % capture all downstream responses.
              mc_downstream:accum(
                mc_downstream:send(Addr, {Id, Addr}, Cmd, CmdArgs,
                                   ResponseFilter, ?MODULE,
                                   self(), {Id, Addr}), Acc)
          end,
          {0, []}, Addrs),
    Replicator =
        create_replicator(Id, Request, NotifyPid, undefined,
                          SentOk, Monitors),
    Replicators2 =
        case update_replicator(Replicator) of
            {ok, R}    -> dict:store(Id, R, Replicators);
            {done, _}  -> dict:erase(Id, Replicators);
            {error, _} -> dict:erase(Id, Replicators)
        end,
    {reply, {ok, []}, RMgr#rmgr{curr = Replicators2}}.

handle_cast({response, Id, Addr, RV},
            #rmgr{curr = Replicators} = RMgr) ->
    % Invoked when a downstream sends some more partial response.
    case dict:find(Id, Replicators) of
        {ok, #replicator{responses = Responses} = Replicator} ->
            Replicators2 =
                dict:store(Id,
                           Replicator#replicator{
                             responses = [{Addr, RV} | Responses]
                           },
                           Replicators),
            {noreply, RMgr#rmgr{curr = Replicators2}};
        error ->
            {noreply, RMgr}
    end.

handle_info({{Id, Addr}, RV},
            #rmgr{curr = Replicators} = RMgr) ->
    % Invoked when a downstream provides a final notification result.
    case dict:find(Id, Replicators) of
        {ok, #replicator{responses = Responses,
                         received_ok = ROk,
                         received_err = RErr} = Replicator} ->
            {ROk2, RErr2} = case RV of
                                {ok, _}    -> {ROk + 1, RErr};
                                {ok, _, _} -> {ROk + 1, RErr};
                                _          -> {ROk, RErr + 1}
                            end,
            Replicator2 = Replicator#replicator{
                            responses = [{Addr, RV} | Responses],
                            received_ok = ROk2,
                            received_err = RErr2
                          },
            Replicators2 =
                case update_replicator(Replicator2) of
                    {ok, R}    -> dict:store(Id, R, Replicators);
                    {done, _}  -> dict:erase(Id, Replicators);
                    {error, _} -> dict:erase(Id, Replicators)
                end,
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

create_replicator(Id, Request, NotifyPid, NotifyData,
                  SentOk, Monitors) ->
    #replicator{id           = Id,
                request      = Request,
                notify_pid   = NotifyPid,
                notify_data  = NotifyData,
                sent_ok      = SentOk,
                monitors     = Monitors,
                received_ok  = 0,
                received_err = 0}.

update_replicator(#replicator{request         = Request,
                              sent_ok         = SentOk,
                              monitors        = Monitors,
                              received_ok     = ReceivedOk,
                              received_err    = ReceivedErr
                             } = Replicator) ->
    ReceivedOkMin = Request#request.received_ok_min,
    case SentOk >= ReceivedOkMin of
        true ->
            case ReceivedOk + ReceivedErr >= SentOk of
                true ->
                    mc_downstream:demonitor(Monitors),
                    notify_replicator(Replicator),
                    {done, all_responses_received};
                false ->
                    case ReceivedOk == ReceivedOkMin of
                        true  -> notify_replicator(Replicator);
                        false -> {ok, Replicator}
                    end
            end;
        false ->
            mc_downstream:demonitor(Monitors),
            notify_replicator(Replicator),
            {error, not_enough_active_replicas}
    end.

notify_replicator(#replicator{notify_pid  = NotifyPid,
                              notify_data = NotifyData} = Replicator) ->
    notify_replicator(NotifyPid, NotifyData, Replicator).

notify_replicator(undefined, _, Replicator) ->
    {ok, Replicator};

notify_replicator(NotifyPid, NotifyData,
                  #replicator{request   = Request,
                              responses = Responses} = Replicator) ->
    RList = lists:reverse(Responses),
    % TODO: Allow caller to provide a best-response callback strategy.
    case first_response(RList) of
        {Addr, RV} ->
            case Request#request.response_module of
                undefined -> ok;
                ResMod ->
                    Out = Request#request.out,
                    lists:foreach(
                      fun (X) ->
                          case X of
                              {Addr, {response, Kind,
                                      Cmd, Head, Body}} ->
                                  ResMod:send_response(Kind, Out,
                                                       Cmd, Head, Body);
                              _ -> ok
                          end
                      end,
                      RList)
            end,
            notify(NotifyPid, NotifyData, RV);
        undefined ->
            notify(NotifyPid, NotifyData, {error, no_response})
    end,
    % TODO: Consider erasing the responses, too.
    {ok, Replicator#replicator{notify_pid = undefined,
                               notify_data = undefined}}.

notify(P, D, V) when is_pid(P) -> P ! {D, V};
notify(_, _, _)                -> ok.

first_response([])                         -> undefined;
first_response([{_Addr, RV} = Head | Rest]) ->
    case RV of
        {ok, _}    -> Head;
        {ok, _, _} -> Head;
        _          -> first_response(Rest)
    end.
