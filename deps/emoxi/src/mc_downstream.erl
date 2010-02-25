% Copyright (c) 2009, NorthScale, Inc.
% All rights reserved.

-module(mc_downstream).

-behavior(gen_server).

-include_lib("eunit/include/eunit.hrl").

-include("mc_constants.hrl").

-include("mc_entry.hrl").

%% API
-export([start_link/0, start_link/1,
         send/6, send/8, kind_to_module/1,
         await_ok/1, accum/2]).

%% Does not belong here.
-export([group_by/2, demonitor/1]).

%% gen_server
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(TIMEOUT_AWAIT_OK,         100000). % 100 seconds.
-define(TIMEOUT_WORKER_GO,          1000). % 1 seconds.
-define(TIMEOUT_WORKER_INACTIVE, 1000000). % 1000 seconds.

-record(dmgr, {timeout % Timeout for worker inactivity.
              }).

% We have one MBox (or worker) per Addr.
%
-record(mbox, {addr, pid, started}).

%% API for downstream manager service.
%%
%% This module is unaware of pools or buckets.  It only knows of and
%% manages connections to individual downstream targets (or Addr/MBox
%% pairs).  For example, multiple buckets or pools in this erlang VM
%% might be sharing the downstream targets.  When a downstream dies,
%% all the higher level layers can learn of it via this module's
%% monitor/demonitor abstraction.

start_link()     -> start_link([{timeout, ?TIMEOUT_WORKER_INACTIVE}]).
start_link(Args) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

send(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule) ->
    send(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule,
         self(), undefined).

send(Addr, Out, Cmd, CmdArgs, ResponseFilter, ResponseModule,
     NotifyPid, NotifyData) ->
    Kind = mc_addr:kind(Addr),
    ResponseFun =
        fun(Head, Body, CBData) ->
                case ((not is_function(ResponseFilter)) orelse
                      (ResponseFilter(Head, Body))) of
                    true ->
                        case ResponseModule of
                            undefined -> ok;
                            _ -> ResponseModule:send_response(Kind, Out,
                                                              Cmd, Head, Body)
                        end;
                    false -> ok
                end,
                CBData
        end,
    case gen_server:call(?MODULE, {pid, Addr}) of
        {ok, MBoxPid} ->
            Monitor = erlang:monitor(process, MBoxPid),
            MBoxPid ! {send, NotifyPid, NotifyData, ResponseFun,
                       kind_to_module(Kind), Cmd, CmdArgs},
            {ok, [Monitor]};
        Error -> Error
    end.

kind_to_module(ascii)  -> mc_client_ascii_ac;
kind_to_module(binary) -> mc_client_binary_ac.

demonitor(undefined) -> ok;
demonitor(MonitorRefs) ->
    %% The flush removes a single DOWN message, if any, that are
    %% already waiting in our/self()'s mailbox.
    lists:foreach(fun(MonitorRef) ->
                          erlang:demonitor(MonitorRef, [flush])
                  end,
                  MonitorRefs),
    ok.

% Accumulate results of send calls, useful with foldl.
accum(CallResult, {NumOks, AccMonitors}) ->
    case CallResult of
        {ok, Monitors} -> {NumOks + 1, Monitors ++ AccMonitors};
        {_,  Monitors} -> {NumOks, Monitors ++ AccMonitors}
    end.

await_ok(N) -> await_ok(undefined, N, ?TIMEOUT_AWAIT_OK, 0).
await_ok(Prefix, N, T, Acc) when N > 0 ->
    % TODO: Decrementing N due to a DOWN might be incorrect
    %       during edge/race conditions.
    % TODO: Need to match the MonitorRef's we get from 'DOWN' messages?
    %
    % Receive messages from worker processes doing a notify().
    receive
        {Prefix, {ok, _}}              -> await_ok(Prefix, N - 1, T, Acc + 1);
        {Prefix, {ok, _, _}}           -> await_ok(Prefix, N - 1, T, Acc + 1);
        {Prefix, {ok, _, _, _}}        -> await_ok(Prefix, N - 1, T, Acc + 1);
        {Prefix, _}                    -> await_ok(Prefix, N - 1, T, Acc);
        {'DOWN', _MonitorRef, _, _, _} -> await_ok(Prefix, N - 1, T, Acc);
        Other ->
            exit({unhandled, ?MODULE, await_ok, Other})
    after T ->
        % When we've waited too long, free up the caller.
        % TODO: Need to demonitor?
        Acc
    end;
await_ok(_, _, _, Acc) -> Acc.

%% gen_server implementation.

init([{timeout, Timeout}]) ->
    {ok, #dmgr{timeout = Timeout}}.

terminate(_Reason, _DMgr) -> ok.
code_change(_OldVn, DMgr, _Extra) -> {ok, DMgr}.

handle_info(_Info, DMgr) -> {noreply, DMgr}.

handle_cast(_Msg, DMgr) -> {noreply, DMgr}.

handle_call({pid, Addr}, _From, DMgr) ->
    case make_mbox(DMgr, Addr) of
        {ok, DMgr2, #mbox{pid = MBoxPid}} ->
            Reply = {ok, MBoxPid},
            {reply, Reply, DMgr2};
        Error ->
            {reply, Error, DMgr}
    end;

handle_call({send, Addr, Op, NotifyPid, NotifyData,
             ResponseFun, CmdModule, Cmd, CmdArgs}, _From, DMgr) ->
    case make_mbox(DMgr, Addr) of
        {ok, DMgr2, #mbox{pid = MBoxPid}} ->
            MBoxPid ! {Op, NotifyPid, NotifyData, ResponseFun,
                       CmdModule, Cmd, CmdArgs},
            {reply, ok, DMgr2};
        Error ->
            {reply, Error, DMgr}
    end.

% ---------------------------------------------------

% Retrieves or starts an mbox for an Addr.
make_mbox(State, Addr) ->
    case mc_downstream_sup:add_downstream(Addr, State#dmgr.timeout) of
        {ok, Child}                       -> {ok, Child};
        {error, {already_started, Child}} -> {ok, Child};
        Err                               -> Err
    end.

group_by(Keys, KeyFunc) ->
    group_by(Keys, KeyFunc, dict:new()).

group_by([Key | Rest], KeyFunc, Dict) ->
    G = KeyFunc(Key),
    group_by(Rest, KeyFunc,
             dict:update(G, fun(V) -> [Key | V] end, [Key], Dict));
group_by([], _KeyFunc, Dict) ->
    lists:map(fun({G, Val}) -> {G, lists:reverse(Val)} end,
              dict:to_list(Dict)).

% ---------------------------------------------------

% For testing...
%

element2({_X, Y}) -> Y.

group_by_edge_test() ->
    ?assertMatch([],
                 group_by([],
                          fun element2/1)),
    ?assertMatch([{1, [{a, 1}]}],
                 group_by([{a, 1}],
                          fun element2/1)),
    ok.

group_by_simple_test() ->
    ?assertMatch([{1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {b, 1}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {b, 1}, {c, 2}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{a, 1}, {c, 2}, {b, 1}],
                          fun element2/1)),
    ?assertMatch([{2, [{c, 2}]},
                  {1, [{a, 1}, {b, 1}]}],
                 group_by([{c, 2}, {a, 1}, {b, 1}],
                          fun element2/1)),
    ok.
