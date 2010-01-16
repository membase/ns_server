% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_server_binary_proxy).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_downstream, [accum/2, await_ok/1, group_by/2]).

-import(mc_replication, [send/7]).

-compile(export_all).

-record(session_proxy, {pool,
                        bucket, % The target that we're forwarding to.
                        authed, % Either false, or when auth_ok() timestamp.
                        corked  % Requests awaiting a NOOP to uncork.
                       }).

session(_Sock, Pool) ->
    {ok, Sess} = session_init(#session_proxy{}, Pool),
    {ok, Pool, Sess}.

session_init(Sess, Pool) ->
    {ok, Bucket} = mc_pool:get_bucket(Pool, "default"),
    {ok, Sess#session_proxy{pool = Pool,
                            bucket = Bucket,
                            authed = false,
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

cmd(?SETQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?ADDQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?REPLACEQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?DELETEQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?INCREMENTQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?DECREMENTQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?APPENDQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);
cmd(?PREPENDQ, Sess, _Sock, Out, HE) ->
    queue_update(Sess, Out, HE);

% ------------------------------------------

cmd(?FLUSH = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(all, O, Sess, Out, HE);
cmd(?FLUSHQ = O, Sess, _Sock, _Out, HE) ->
    forward_bcast_filter(all, O, Sess, undefined, HE);
cmd(?NOOP = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(uncork, O, Sess, Out, HE);

% ------------------------------------------

cmd(?STAT = O, Sess, _Sock, Out, {H, _E} = HE) ->
    {ok, Stats} = mc_stats:start_link(),
    ResponseFilter =
        fun (#mc_header{status = ?SUCCESS},
             #mc_entry{key = KeyBin, data = DataBin}) ->
                case mc_binary:bin_size(KeyBin) > 0 of
                    true  -> mc_stats:stats_more(Stats, KeyBin, DataBin),
                             false;
                    false -> false
                end;
            (LineBin, undefined) ->
                mc_stats:stats_more(Stats, LineBin),
                false;
            (_, _) ->
                false
        end,
    % Using undefined Out to swallow the downstream responses,
    % which we'll handle with our ResponseFilter.
    {NumFwd, Monitors} =
        forward_bcast(all_send, O, Sess, undefined, HE, ResponseFilter),
    await_ok(NumFwd),
    {ok, StatsResults} = mc_stats:stats_done(Stats),
    lists:foreach(fun({KeyBin, DataBin}) ->
                          mc_binary:send(Out, res,
                                         H#mc_header{status = ?SUCCESS},
                                         #mc_entry{key = KeyBin,
                                                   data = DataBin})
                  end,
                  StatsResults),
    mc_binary:send(Out, res, H#mc_header{status = ?SUCCESS}, #mc_entry{}),
    mc_downstream:demonitor(Monitors),
    {ok, Sess};

% ------------------------------------------

cmd(?CMD_SASL_LIST_MECHS, Sess, _Sock, Out, {H, _E}) ->
    mc_binary:send(Out, res,
                   H#mc_header{status = ?SUCCESS},
                   #mc_entry{data = "PLAIN"}),
    {ok, Sess};

cmd(?CMD_SASL_AUTH, Sess, _Sock, Out, {H, #mc_entry{key = Mech,
                                                    data = Data}}) ->
    auth(Mech, Data, Sess, Out, H);

% ------------------------------------------

cmd(?VERSION, Sess, _Sock, Out, {Header, _Entry}) ->
    V = case catch(ns_config:search(version)) of
            {value, X} -> X;
            false      -> "X.X.X";
            _          -> "unknown"
        end,
    mc_binary:send(Out, res, Header, #mc_entry{data = V}),
    {ok, Sess};

cmd(?QUIT, _Sess, _Sock, Out, {H, _E}) ->
    % TODO: Sending directly to Sock instead of Out to pass memcapable.
    %       But, this might bypass any messages queued on the Out pid.
    %
    mc_binary:send(Out, res, H#mc_header{status = ?SUCCESS}, #mc_entry{}),
    mc_binary:flush(Out),
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

auth("PLAIN" = Mech, Data, #session_proxy{pool = Pool} = Sess, Out, H) ->
    DataStr = binary_to_list(Data),
    DataAuth =
        case string:tokens(DataStr, "\0") of
            [AuthName, AuthPswd]          -> {AuthName, AuthName, AuthPswd};
            [ForName, AuthName, AuthPswd] -> {ForName, AuthName, AuthPswd};
            _                             -> error
        end,
    case mc_pool:auth_to_bucket(Pool, Mech, DataAuth) of
        {ok, Bucket} ->
            mc_binary:send(Out, res,
                           H#mc_header{status = ?SUCCESS},
                           #mc_entry{}),
            % TODO: Revisit corked data on a auth/re-auth.
            {ok, Sess#session_proxy{bucket = Bucket,
                                    authed = erlang:now()}};
        _Error ->
            mc_binary:send(Out, res,
                           H#mc_header{status = ?EINVAL},
                           #mc_entry{}),
            session_init(Sess, Pool)
    end;

auth(_UnknownMech, _Data, #session_proxy{pool = Pool} = Sess, Out, H) ->
    mc_binary:send(Out, res,
                   H#mc_header{status = ?KEY_ENOENT},
                   #mc_entry{}),
    session_init(Sess, Pool).

% ------------------------------------------

% ?BUCKET

% ------------------------------------------

% Enqueue the request as part of the session, which a
% future NOOP request should uncork.
%
% TODO: Any future non-quiet command needs to uncork, too.
%
queue(#session_proxy{corked = C} = Sess, HE) ->
    {ok, Sess#session_proxy{corked = [HE | C]}}.

queue_update(#session_proxy{corked = []} = Sess, Out, HE) ->
    % If we're the only corked entry, send a NOOP, to pass memcapable.
    {ok, Sess2} = queue(Sess, HE),
    forward_bcast_uncork(?NOOP, Sess2, Out, undefined,
                         {#mc_header{opcode = ?NOOP}, #mc_entry{}});

queue_update(Sess, _Out, HE) ->
    % Otherwise, we expect the caller will send an explicit NOOP
    % request to uncork.
    queue(Sess, HE).

% For binary commands that need a simple command forward.
forward_simple(Opcode, #session_proxy{bucket = Bucket} = Sess, Out,
               {Header, #mc_entry{key = Key}} = HE) ->
    {Key, Addrs, _Config} = mc_bucket:choose_addrs(Bucket, Key),
    case send(Addrs, Out, Opcode, HE, undefined, ?MODULE, undefined) of
        {ok, Monitors} ->
            1 = await_ok(1),
            mc_downstream:demonitor(Monitors);
        _Error ->
            mc_binary:send(Out, res,
                           Header#mc_header{status = ?ENOMEM}, #mc_entry{})
    end,
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
              Out, {H, _E} = HE, ResponseFilter) ->
    {NumFwd, Monitors} =
        forward_bcast(all_send, Opcode, Sess, Out, HE, ResponseFilter),
    await_ok(NumFwd),
    mc_binary:send(Out, res, H#mc_header{status = ?SUCCESS}, #mc_entry{}),
    mc_downstream:demonitor(Monitors),
    {ok, Sess};

% For binary commands to do a broadcast scatter/gather,
% grouping and uncorking queued requests.
% A ResponseFilter can be used to filter out responses.
forward_bcast(uncork, Opcode, Sess,
              Out, HE, ResponseFilter) ->
    forward_bcast_uncork(Opcode, Sess,
                         Out, Out, HE, ResponseFilter).

% Calls forward_bcast, but filters out any responses
% that have the same Opcode as the request.
forward_bcast_filter(BCastKind, Opcode, Sess, Out, HE) ->
    ResponseFilter =
        fun (#mc_header{opcode = ROpcode}, _REntry) ->
            ROpcode =/= Opcode
        end,
    forward_bcast(BCastKind, Opcode, Sess, Out, HE, ResponseFilter).

forward_bcast_uncork(_Opcode, #session_proxy{bucket = Bucket,
                                             corked = C} = Sess,
                     OutCork, OutFinal, {H, E} = HE, ResponseFilter) ->
    % Group our corked requests by Addr.
    Groups =
        group_by(C, fun ({_CorkedHeader, #mc_entry{key = Key}}) ->
                        {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
                        Addr
                    end),
    % Forward the request list to each Addr.
    {NumFwd, Monitors} =
        lists:foldl(fun ({Addr, HEList}, Acc) ->
                        accum(send([Addr], OutCork, send_list,
                                   lists:reverse([HE | HEList]),
                                   ResponseFilter, ?MODULE,
                                   undefined), Acc)
                    end,
                    {0, []}, Groups),
    await_ok(NumFwd),
    mc_binary:send(OutFinal, res, H#mc_header{status = ?SUCCESS}, E),
    mc_downstream:demonitor(Monitors),
    {ok, Sess#session_proxy{corked = []}}.

forward_bcast_uncork(Opcode, Sess, OutCork, OutFinal, HE) ->
    ResponseFilter =
        fun (#mc_header{opcode = ROpcode}, _REntry) ->
            ROpcode =/= Opcode
        end,
    forward_bcast_uncork(Opcode, Sess, OutCork, OutFinal, HE,
                         ResponseFilter).

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

