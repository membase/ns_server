-module(mc_server_binary_proxy).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

-import(mc_downstream, [forward/6, accum/2, await_ok/1]).

-compile(export_all).

-record(session_proxy, {bucket}).

session(_Sock, Pool, _ProtocolModule) ->
    {ok, Bucket} = mc_pool:get_bucket(Pool, "default"),
    {ok, Pool, #session_proxy{bucket = Bucket}}.

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

cmd(?GETQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?GETKQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?SETQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?ADDQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?REPLACEQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?DELETEQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?INCREMENTQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?DECREMENTQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?APPENDQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);
cmd(?PREPENDQ = O, Sess, _Sock, Out, HE) ->
    forward_simple(O, Sess, Out, HE);

% ------------------------------------------

cmd(?FLUSH = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(O, Sess, Out, HE);
cmd(?NOOP = O, Sess, _Sock, Out, HE) ->
    forward_bcast_filter(O, Sess, Out, HE);

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

% For binary commands that need a simple command forward.
forward_simple(Opcode, #session_proxy{bucket = Bucket} = Sess, Out,
               {_Header, #mc_entry{key = Key}} = HE) ->
    {Key, Addr} = mc_bucket:choose_addr(Bucket, Key),
    {ok, Monitor} = forward(Addr, Out, Opcode, HE, undefined, ?MODULE),
    true = await_ok(1), % TODO: Send err response instead of conn close?
    mc_downstream:demonitor([Monitor]),
    {ok, Sess}.

% For binary commands to do a broadcast scatter/gather.
% A ResponseFilter can be used to filter out responses.
forward_bcast(Opcode, #session_proxy{bucket = Bucket} = Sess, Out, HE,
              ResponseFilter) ->
    Addrs = mc_bucket:addrs(Bucket),
    {NumFwd, Monitors} =
        lists:foldl(fun (Addr, Acc) ->
                        % Using undefined Out to swallow the OK
                        % responses from the downstreams.
                        accum(forward(Addr, Out, Opcode, HE,
                                      ResponseFilter, ?MODULE), Acc)
                    end,
                    {0, []}, Addrs),
    await_ok(NumFwd),
    mc_ascii:send(Out, <<"OK\r\n">>),
    mc_downstream:demonitor(Monitors),
    {ok, Sess}.

% Same as forward_bcast, but filters out any responses
% that have the same Opcode as the request.
forward_bcast_filter(Opcode, Sess, Out, HE) ->
    ResponseFilter =
        fun (#mc_header{opcode = ROpcode}, _REntry) ->
            ROpcode =:= Opcode
        end,
    forward_bcast(Opcode, Sess, Out, HE, ResponseFilter).

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

