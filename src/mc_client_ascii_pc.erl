-module(mc_client_ascii_pc).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_client.hrl").

-compile(export_all).

%% A memcached client that speaks ascii protocol,
%% with a "protocol conversion" interface.

cmd(Cmd, Sock, RecvCallback, Entry) when is_atom(Cmd) ->
    mc_client_ascii:cmd(Cmd, Sock, RecvCallback, Entry);

cmd(Cmd, Sock, RecvCallback, Entry) ->
    % Dispatch to cmd_binary() in case the caller was
    % using a binary protocol opcode.
    cmd_binary(Cmd, Sock, RecvCallback, Entry).

% -------------------------------------------------

%% For binary upstream talking to downstream ascii server.
%% The RecvCallback function will receive ascii-oriented parameters.

cmd_binary(?GET, _S, _RC, _E) -> exit(todo);

cmd_binary(?SET, Sock, RecvCallback, Entry) ->
    cmd(set, Sock, RecvCallback, Entry);

cmd_binary(?ADD, _S, _RC, _E) -> exit(todo);
cmd_binary(?REPLACE, _S, _RC, _E) -> exit(todo);

cmd_binary(?DELETE, Sock, RecvCallback, Entry) ->
    cmd(delete, Sock, RecvCallback, Entry);

cmd_binary(?INCREMENT, _S, _RC, _E) -> exit(todo);
cmd_binary(?DECREMENT, _S, _RC, _E) -> exit(todo);
cmd_binary(?QUIT, _S, _RC, _E) -> exit(todo);

cmd_binary(?FLUSH, Sock, RecvCallback, Entry) ->
    cmd(flush_all, Sock, RecvCallback, Entry);

cmd_binary(?GETQ, _S, _RC, _E) -> exit(todo);

cmd_binary(?NOOP, _Sock, RecvCallback, _Entry) ->
    % Assuming NOOP used to uncork GETKQ's.
    if is_function(RecvCallback) -> RecvCallback(<<"END">>,
                                                 #mc_entry{});
       true -> ok
    end;

cmd_binary(?VERSION, _S, _RC, _E) -> exit(todo);
cmd_binary(?GETK, _S, _RC, _E) -> exit(todo);

cmd_binary(?GETKQ, Sock, RecvCallback, #mc_entry{keys = Keys}) ->
    cmd(get, Sock, RecvCallback, #mc_entry{keys = Keys});

cmd_binary(?APPEND, _S, _RC, _E) -> exit(todo);
cmd_binary(?PREPEND, _S, _RC, _E) -> exit(todo);
cmd_binary(?STAT, _S, _RC, _E) -> exit(todo);
cmd_binary(?SETQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?ADDQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?REPLACEQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?DELETEQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?INCREMENTQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?DECREMENTQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?QUITQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?FLUSHQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?APPENDQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?PREPENDQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?RGET, _S, _RC, _E) -> exit(todo);
cmd_binary(?RSET, _S, _RC, _E) -> exit(todo);
cmd_binary(?RSETQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?RAPPEND, _S, _RC, _E) -> exit(todo);
cmd_binary(?RAPPENDQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?RPREPEND, _S, _RC, _E) -> exit(todo);
cmd_binary(?RPREPENDQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?RDELETE, _S, _RC, _E) -> exit(todo);
cmd_binary(?RDELETEQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?RINCR, _S, _RC, _E) -> exit(todo);
cmd_binary(?RINCRQ, _S, _RC, _E) -> exit(todo);
cmd_binary(?RDECR, _S, _RC, _E) -> exit(todo);
cmd_binary(?RDECRQ, _S, _RC, _E) -> exit(todo);

cmd_binary(Cmd, _S, _RC, _E) -> exit({unimplemented, Cmd}).

