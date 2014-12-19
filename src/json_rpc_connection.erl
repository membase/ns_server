%% @author Couchbase <info@couchbase.com>
%% @copyright 2014 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(json_rpc_connection).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start/2,
         perform_call/3, perform_call/4,
         have_named_connection/1,
         handle_rpc_connect/1,
         reannounce/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {counter :: non_neg_integer(),
                sock :: port(),
                id_to_caller_tid :: ets:tid()}).

-define(PREFIX, "json_rpc_connection-").

label_to_name(Pid) when is_pid(Pid) ->
    Pid;
label_to_name(Label) ->
    list_to_atom(?PREFIX ++ atom_to_list(Label)).

start(Label, InetSock) ->
    {ok, Pid} = gen_server:start(?MODULE, {self(), Label}, []),
    ok = gen_tcp:controlling_process(InetSock, Pid),
    receive
        {'$gen_call', {Pid, _} = From, get_sock}  ->
            gen_server:reply(From, InetSock)
    end,
    {ok, Pid}.

perform_call(Label, Name, EJsonArg, Timeout) ->
    KV = gen_server:call(label_to_name(Label), {call, Name, EJsonArg}, Timeout),
    case lists:keyfind(<<"result">>, 1, KV) of
        false ->
            {_, Error} = lists:keyfind(<<"error">>, 1, KV),
            {error, Error};
        {_, null} ->
            {_, Error} = lists:keyfind(<<"error">>, 1, KV),
            {error, Error};
        {_, Res} ->
            {ok, Res}
    end.

perform_call(Label, Name, EJsonArg) ->
    perform_call(Label, Name, EJsonArg, infinity).

have_named_connection(Label) ->
    erlang:whereis(label_to_name(Label)) =/= undefined.

handle_rpc_connect(Req) ->
    "/" ++ Path = Req:get(path),
    Sock = Req:get(socket),
    menelaus_util:reply(Req, 200),
    {ok, _} = json_rpc_connection:start(list_to_atom(Path), Sock),
    erlang:exit(normal).


init({Starter, Label}) ->
    proc_lib:init_ack({ok, self()}),
    InetSock = gen_server:call(Starter, get_sock, 5000),
    Name = label_to_name(Label),
    case erlang:whereis(Name) of
        undefined ->
            ok;
        ExistingPid ->
            erlang:exit(ExistingPid, new_instance_created),
            misc:wait_for_process(ExistingPid, infinity)
    end,
    true = erlang:register(Name, self()),
    ok = inet:setopts(InetSock, [{nodelay, true}]),
    IdToCaller = ets:new(ets, [set, private]),
    _ = proc_lib:spawn_link(erlang, apply, [fun receiver_loop/3, [InetSock, self(), <<>>]]),
    ?log_debug("connected"),
    gen_event:notify(json_rpc_events, {started, Label, self()}),
    {ok, #state{counter = 0,
                sock = InetSock,
                id_to_caller_tid = IdToCaller}}.

reannounce() ->
    lists:map(fun (Name) ->
                      case atom_to_list(Name) of
                          ?PREFIX ++ Label ->
                              gen_event:notify(json_rpc_events,
                                               {needs_update, list_to_existing_atom(Label),
                                                whereis(Name)});
                          _ ->
                              ok
                      end
              end, registered()).

handle_cast(_Msg, _State) ->
    erlang:error(unknown).

handle_info({chunk, Chunk}, #state{id_to_caller_tid = IdToCaller} = State) ->
    {KV} = ejson:decode(Chunk),
    {_, Id} = lists:keyfind(<<"id">>, 1, KV),
    [{_, From}] = ets:lookup(IdToCaller, Id),
    ets:delete(IdToCaller, Id),
    ?log_debug("got response: ~p", [KV]),
    gen_server:reply(From, KV),
    {noreply, State};
handle_info(socket_closed, State) ->
    ?log_debug("Socket closed"),
    {stop, shutdown, State};
handle_info(Msg, State) ->
    ?log_debug("Unknown msg: ~p", [Msg]),
    {noreply, State}.

handle_call({call, Name, EJsonArg}, From, #state{counter = Counter,
                                                 id_to_caller_tid = IdToCaller,
                                                 sock = Sock} = State) ->
    NameB = if
                is_list(Name) ->
                    list_to_binary(Name);
                true ->
                    Name
            end,
    MaybeParams = case EJsonArg of
                      undefined ->
                          [];
                      _ ->
                          %% golang's jsonrpc only supports array of
                          %% single arg
                          [{params, [EJsonArg]}]
                  end,
    EJSON = {[{jsonrpc, <<"2.0">>},
              {id, Counter},
              {method, NameB}
              | MaybeParams]},
    ?log_debug("sending jsonrpc call:~p", [EJSON]),
    ok = gen_tcp:send(Sock, [ejson:encode(EJSON) | <<"\n">>]),
    ets:insert(IdToCaller, {Counter, From}),
    {noreply, State#state{counter = Counter + 1}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


receiver_loop(Sock, Parent, Acc) ->
    RecvData = case gen_tcp:recv(Sock, 0) of
                   {error, closed} ->
                       Parent ! socket_closed,
                       erlang:exit(normal);
                   {ok, XRecvData} ->
                       XRecvData
               end,
    Data = case Acc of
               <<>> ->
                   RecvData;
               _ ->
                   <<Acc/binary, RecvData/binary>>
           end,
    NewAcc = receiver_handle_data(Parent, Data),
    receiver_loop(Sock, Parent, NewAcc).

receiver_handle_data(Parent, Data) ->
    case binary:split(Data, <<"\n">>) of
        [Chunk, <<>>] ->
            Parent ! {chunk, Chunk},
            <<>>;
        [Chunk, Rest] ->
            Parent ! {chunk, Chunk},
            receiver_handle_data(Parent, Rest);
        [SingleChunk] ->
            SingleChunk
    end.
