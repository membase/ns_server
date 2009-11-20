-module(wrn).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-compile(export_all).

%% A generic W+R>N replication implementation.
%%
%% It's generic in that the actual implementation of a request,
%% response and replica node is abstracted out.  Just duck typing.
%%
%% ReplicaNodes -- list of nodes, higher priority first.
%% ReplicaMin   -- minimum # of nodes to replicate to.
%%
%% ------------------------------------------------------

-record(s, {
    mgr,               % Pid of manager.
    send,              % calbackk fun (vocal|quiet, Request, S).
    request,
    replica_nodes,
    replica_min,
    replica_next = 1,
    received_err = 0,
    received_ok  = 0,
    sent_err     = [], % List of {Node, Err} tuples.
    sent_ok      = [], % List of Nodes that had send successes.
    responses    = []  % List of {Node, []}.
}).

create_replicator(Mgr, Send, Request, ReplicaNodes, ReplicaMin) ->
    #s{mgr = Mgr,
       send = Send,
       request = Request,
       replica_nodes = ReplicaNodes,
       replica_min = ReplicaMin}.

% Function to keep the invariant where we've sent the request
% successfully to replica_min number of working replica nodes,
% unless we just run out of replica nodes.
send(S) ->
    StartSentOk = length(S#s.sent_ok),
    S2 = send_loop(S),
    {length(S2#s.sent_ok) > StartSentOk, S2}.

send_loop(S) ->
    #s{send = Send,
       replica_next  = ReplicaNext,
       replica_nodes = ReplicaNodes,
       replica_min   = ReplicaMin,
       sent_ok       = SentOk,
       received_err  = ReceivedErr
      } = S,
    case (ReplicaNext =< length(ReplicaNodes)) andalso
         ((length(SentOk) - ReceivedErr) < ReplicaMin) of
        true ->
            ReplicaNode = lists:nth(ReplicaNext, ReplicaNodes),
            {RV, S2} = Send(vocal, S#s.request, S),
            case RV of
                ok ->
                    S2#s{sent_ok = ReplicaNode ++ S2#s.sent_ok,
                         replica_next = ReplicaNext + 1
                        };
                _X ->
                    S2#s{sent_err = {ReplicaNode, RV} ++ S2#s.sent_err,
                         replica_next = ReplicaNext + 1
                        }
            end;
        false ->
            S
    end.

% Creates and runs a replicator for a single request.
%
replicate_request(S) ->
    % Send out the request to replica_min number of replica nodes or
    % until we just don't have enough working replica_nodes.
    S2 = send(S),

    % Wait for responses to what we successfully sent.  If we received
    % an error, do another round of send() of the request to a
    % remaining replica, if any are left.

    case (S2#s.received_ok + S2#s.received_err) < length(S2#s.sent_ok) of
        true ->
            receive
                {ok} ->
                    replicate_request(#s{received_ok = S2#s.received_ok + 1});
                {error} ->
                    replicate_request(#s{received_err = S2#s.received_err + 1})
            end;
        false ->
            case S2#s.received_ok < S2#s.replica_min of
                true  -> {error, not_enough_replicas};
                false -> {ok}
            end
    end.

replicate_request(Send, Request, ReplicaNodes, ReplicaMin) ->
    S = create_replicator(ok, Send, Request, ReplicaNodes, ReplicaMin),
    replicate_request(S).

