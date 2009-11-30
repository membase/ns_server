-module(mc_server_binary_proxy).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_downstream, [accum/2, await_ok/1, group_by/2]).

-import(mc_replication, [send/7]).

-compile(export_all).

-record(session_proxy, {bucket, % The target that we're forwarding to.
                        corked  % Requests awaiting a NOOP to uncork.
                       }).

session(_Sock, Pool) ->
    {ok, Bucket} = mc_pool:get_bucket(Pool, "default"),
    {ok, Pool, #session_proxy{bucket = Bucket,
                              corked = []}}.

% ------------------------------------------

cmd(?GET = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?SET = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?ADD = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?REPLACE = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?DELETE = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?INCREMENT = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?DECREMENT = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?GETK = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?APPEND = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?PREPEND = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);

cmd(?GETQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?GETKQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?SETQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?ADDQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?REPLACEQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?DELETEQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?INCREMENTQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?DECREMENTQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?APPENDQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);
cmd(?PREPENDQ, Sess, _Sock, _Out, HE) ->
    queue(Sess, HE);

% ------------------------------------------

cmd(?FLUSH = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(all, O, Sess, Out, HE);
cmd(?NOOP = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(uncork, O, Sess, Out, HE);

% ------------------------------------------

cmd(?QUIT, _Sess, _Sock, _Out, _HE) ->
    exit({ok, quit_received});
cmd(?QUITQ, _Sess, _Sock, _Out, _HE) ->
    exit({ok, quit_received}).

% ------------------------------------------

% ?FLUSHQ
% ?VERSION
% ?STAT
% ?SASL_LIST_MECHS
% ?SASL_AUTH
% ?SASL_STEP
% ?BUCKET

% ------------------------------------------

% Enqueue the request as part of the session, which a
% future NOOP request should uncork.
queue(#session_proxy{corked = C} = Sess, HE) ->
    {ok, Sess#session_proxy{corked = [HE | C]}}.

% For binary commands that need a simple command forward.
forward_simple(Opcode, #session_proxy{bucket = Bucket} = Sess, Out,
               {_Header, #mc_entry{key = Key}} = HE) ->
    {Key, Addrs, Policy} = mc_bucket:choose_addrs(Bucket, Key),
    {ok, Monitors} = send(Addrs, Out, Opcode, HE,
                          undefined, ?MODULE, Policy),
    1 = await_ok(1), % TODO: Send err response instead of conn close?
    mc_downstream:demonitor(Monitors),
    {ok, Sess}.

% For binary commands to do a broadcast scatter/gather.
% A ResponseFilter can be used to filter out responses.
forward_bcast(all, Opcode, #session_proxy{bucket = Bucket} = Sess,
              Out, {H, E} = HE, ResponseFilter) ->
    Addrs = mc_bucket:addrs(Bucket),
    {NumFwd, Monitors} =
        lists:foldl(fun (Addr, Acc) ->
                        accum(send([Addr], Out, Opcode, HE,
                                   ResponseFilter, ?MODULE, undefined),
                              Acc)
                    end,
                    {0, []}, Addrs),
    NumFwd = await_ok(NumFwd), % TODO: Send error instead of closing conn?
    mc_binary:send(Out, res, H#mc_header{status = ?SUCCESS}, E),
    mc_downstream:demonitor(Monitors),
    {ok, Sess};

% For binary commands to do a broadcast scatter/gather,
% grouping and uncorking queued requests.
% A ResponseFilter can be used to filter out responses.
forward_bcast(uncork, _Opcode, #session_proxy{bucket = Bucket,
                                              corked = C} = Sess,
              Out, {H, E} = HE, ResponseFilter) ->
    % Group our corked requests by Addr.
    Groups =
        group_by(C, fun ({_CorkedHeader, #mc_entry{key = Key}}) ->
                        {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                        Addr
                    end),
    % Forward the request list to each Addr.
    {NumFwd, Monitors} =
        lists:foldl(fun ({Addr, HEList}, Acc) ->
                        accum(send([Addr], Out, send_list,
                                   lists:reverse([HE | HEList]),
                                   ResponseFilter, ?MODULE,
                                   undefined), Acc)
                    end,
                    {0, []}, Groups),
    NumFwd = await_ok(NumFwd), % TODO: Send error instead of closing conn?
    mc_binary:send(Out, res, H#mc_header{status = ?SUCCESS}, E),
    mc_downstream:demonitor(Monitors),
    {ok, Sess#session_proxy{corked = []}}.

% Calls forward_bcast, but filters out any responses
% that have the same Opcode as the request.
forward_bcast_filter(BCastKind, Opcode, Sess, Out, HE) ->
    ResponseFilter =
        fun (#mc_header{opcode = ROpcode}, _REntry) ->
            ROpcode =/= Opcode
        end,
    forward_bcast(BCastKind, Opcode, Sess, Out, HE, ResponseFilter).

% ------------------------------------------

send_response(ascii, Out, _Cmd, Head, Body) ->
    % Downstream is ascii.
    (Out =/= undefined) andalso
    ((Head =/= undefined) andalso
     (ok =:= mc_ascii:send(Out, [Head, <<"\r\n">>]))) andalso
    ((Body =:= undefined) orelse
     (ok =:= mc_ascii:send(Out, [Body#mc_entry.data, <<"\r\n">>])));

send_response(binary, Out, _Cmd, Header, Entry) ->
    % Downstream is binary.
    mc_binary:send(Out, res, Header, Entry).

