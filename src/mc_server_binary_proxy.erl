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
cmd(?FLUSHQ = O, Sess, _Sock, _Out, HE) ->
    forward_bcast_filter(all, O, Sess, undefined, HE);
cmd(?NOOP = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(uncork, O, Sess, Out, HE);

% ------------------------------------------

cmd(?STAT = O, Sess, _Sock, Out, {H, _E} = HE) ->
    ResponseFilter =
        fun (<<"STAT ", LineBin/binary>>, undefined) ->
                LineStr = binary_to_list(LineBin),
                [Key, Data | _Rest] = string:tokens(LineStr, " "),
                mc_binary:send(Out, res,
                               H#mc_header{status = ?SUCCESS},
                               #mc_entry{key = Key, data = Data}),
                false;
            (#mc_header{status = ?SUCCESS} = RH,
             #mc_entry{key = KeyBin} = RE) ->
                case mc_binary:bin_size(KeyBin) > 0 of
                    true  -> mc_binary:send(Out, res, RH, RE),
                             false;
                    false -> false
                end;
            (_, _) ->
                false
        end,
    % Using undefined Out to swallow the downstream responses,
    % which we'll handle with our ResponseFilter.
    {NumFwd, Monitors} =
        forward_bcast(all_send, O, Sess, undefined, HE, ResponseFilter),
    NumFwd = await_ok(NumFwd),
    mc_binary:send(Out, res, H#mc_header{status = ?SUCCESS}, #mc_entry{}),
    mc_downstream:demonitor(Monitors),
    {ok, Sess};

% ------------------------------------------

cmd(?VERSION, Sess, _Sock, Out, {Header, _Entry}) ->
    V = case ns_config:search(version) of
            {value, X} -> X;
            false      -> "X.X.X"
        end,
    mc_binary:send(Out, res, Header, #mc_entry{data = V}),
    {ok, Sess};

cmd(?QUIT, _Sess, _Sock, _Out, _HE) ->
    exit({ok, quit_received});
cmd(?QUITQ, _Sess, _Sock, _Out, _HE) ->
    exit({ok, quit_received});

% ------------------------------------------

cmd(_, Sess, _, Out, {Header, _Entry}) ->
    % TODO: Reference c-memcached includes an error string.
    mc_binary:send(Out, res,
                   Header#mc_header{status = ?UNKNOWN_COMMAND}, #mc_entry{}),
    {ok, Sess}.

% ------------------------------------------

% ?STAT
% ?SASL_LIST_MECHS
% ?SASL_AUTH
% ?SASL_STEP
% ?BUCKET

% ------------------------------------------

% Enqueue the request as part of the session, which a
% future NOOP request should uncork.
%
% TODO: Any future non-quiet command needs to uncork, too.
%
queue(#session_proxy{corked = C} = Sess, HE) ->
    {ok, Sess#session_proxy{corked = [HE | C]}}.

% For binary commands that need a simple command forward.
forward_simple(Opcode, #session_proxy{bucket = Bucket} = Sess, Out,
               {_Header, #mc_entry{key = Key}} = HE) ->
    {Key, Addrs, _Config} = mc_bucket:choose_addrs(Bucket, Key),
    {value, MinOk} =
        {value, undefined}, % ns_config:search(Config, replica_kind(Opcode)),
    {ok, Monitors} = send(Addrs, Out, Opcode, HE,
                          undefined, ?MODULE, MinOk),
    1 = await_ok(1),
    mc_downstream:demonitor(Monitors),
    {ok, Sess}.

% For binary commands to do a broadcast scatter (with no
% gather/response processing) in this helper function.
forward_bcast(all_send, Opcode, #session_proxy{bucket = Bucket},
              Out, HE, ResponseFilter) ->
    Addrs = mc_bucket:addrs(Bucket),
    lists:foldl(fun (Addr, Acc) ->
                    accum(send([Addr], Out, Opcode, HE,
                               ResponseFilter, ?MODULE, undefined),
                          Acc)
                end,
                {0, []}, Addrs);

% For binary commands to do a broadcast scatter/gather.
% A ResponseFilter can be used to filter out responses.
forward_bcast(all, Opcode, Sess,
              Out, {H, E} = HE, ResponseFilter) ->
    {NumFwd, Monitors} =
        forward_bcast(all_send, Opcode, Sess, Out, HE, ResponseFilter),
    NumFwd = await_ok(NumFwd),
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
    NumFwd = await_ok(NumFwd),
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

% ------------------------------------------

replica_kind(?GET)   -> replica_r;
replica_kind(?GETK)  -> replica_r;
replica_kind(?GETQ)  -> replica_r;
replica_kind(?GETKQ) -> replica_r;
replica_kind(_)      -> replica_w.

