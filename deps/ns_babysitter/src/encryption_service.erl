%% @author Couchbase <info@couchbase.com>
%% @copyright 2016 Couchbase, Inc.
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
-module(encryption_service).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-export([set_password/1,
         decrypt/1,
         encrypt/1]).

data_key_store_path() ->
    filename:join(path_config:component_path(data, "config"), "encrypted_data_keys").

set_password(Password) ->
    gen_server:call(?MODULE, {set_password, Password}, infinity).

encrypt(Data) ->
    gen_server:call({?MODULE, ns_server:get_babysitter_node()}, {encrypt, Data}, infinity).

decrypt(Data) ->
    gen_server:call({?MODULE, ns_server:get_babysitter_node()}, {decrypt, Data}, infinity).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

prompt_the_password(EncryptedDataKey, State, Try) ->
    ?log_debug("Waiting for the master password to be supplied. Attempt ~p", [Try]),
    receive
        {'$gen_call', From, {set_password, P}} ->
            ok = set_password(P, State),
            case EncryptedDataKey of
                undefined ->
                    gen_server:reply(From, ok),
                    ok;
                _ ->
                    Ret = call_gosecrets({set_data_key, EncryptedDataKey}, State),
                    case Ret of
                        ok ->
                            gen_server:reply(From, ok),
                            ok;
                        Error ->
                            ?log_error("Incorrect master password. Error: ~p", [Error]),
                            maybe_retry_prompt_the_password(EncryptedDataKey, State, From, Try)
                    end
            end
    end.

maybe_retry_prompt_the_password(_EncryptedDataKey, _State, ReplyTo, 1) ->
    gen_server:reply(ReplyTo, auth_failure),
    auth_failure;
maybe_retry_prompt_the_password(EncryptedDataKey, State, ReplyTo, Try) ->
    gen_server:reply(ReplyTo, retry),
    prompt_the_password(EncryptedDataKey, State, Try - 1).

set_password(Password, State) ->
    ?log_debug("Sending password to gosecrets"),
    call_gosecrets({set_password, Password}, State).

init([]) ->
    Path = data_key_store_path(),
    EncryptedDataKey =
        case file:read_file(Path) of
            {ok, DataKey} ->
                ?log_debug("Encrypted data key retrieved from ~p", [Path]),
                DataKey;
            {error, enoent} ->
                ?log_debug("Encrypted data key is not found in ~p", [Path]),
                undefined
        end,
    State = start_gosecrets(),
    case os:getenv("CB_WAIT_FOR_MASTER_PASSWORD") of
        "true" ->
            case prompt_the_password(EncryptedDataKey, State, 3) of
                ok ->
                    ok;
                auth_failure ->
                    exit(incorrect_master_password)
            end;
        _ ->
            Password =
                case os:getenv("CB_MASTER_PASSWORD") of
                    false ->
                        "";
                    S ->
                        S
                end,
            ok = set_password(Password, State)
    end,
    EncryptedDataKey1 =
        case EncryptedDataKey of
            undefined ->
                ?log_debug("Create new data key."),
                {ok, NewDataKey} = call_gosecrets(create_data_key, State),
                ok = misc:mkdir_p(path_config:component_path(data, "config")),
                ok = misc:atomic_write_file(Path, NewDataKey),
                NewDataKey;
            _ ->
                EncryptedDataKey
        end,
    case call_gosecrets({set_data_key, EncryptedDataKey1}, State) of
        ok ->
            ok;
        Error ->
            ?log_error("Incorrect master password. Error: ~p", [Error]),
            exit(incorrect_master_password)
    end,
    {ok, State}.

handle_call({set_password, _}, _From, State) ->
    {reply, {error, not_allowed}, State};
handle_call({encrypt, Data}, _From, State) ->
    {reply, call_gosecrets({encrypt, Data}, State), State};
handle_call({decrypt, Data}, _From, State) ->
    {reply,
     case call_gosecrets({decrypt, Data}, State) of
         ok ->
             {ok, <<>>};
         Ret ->
             Ret
     end, State};
handle_call(_, _From, State) ->
    {reply, {error, not_allowed}, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

start_gosecrets() ->
    Parent = self(),
    {ok, Pid} =
        proc_lib:start_link(
          erlang, apply,
          [fun () ->
                   process_flag(trap_exit, true),
                   Path = path_config:component_path(bin, "gosecrets"),
                   ?log_debug("Starting ~p", [Path]),
                   Port = open_port({spawn_executable, Path}, [{packet, 2}, binary, hide]),
                   proc_lib:init_ack({ok, self()}),
                   gosecrets_loop(Port, Parent)
           end, []]),
    ?log_debug("Gosecrets loop started with pid = ~p", [Pid]),
    Pid.

call_gosecrets(Msg, Pid) ->
    Pid ! {call, Msg},
    receive
        {reply, <<"S">>} ->
            ok;
        {reply, <<"S", Data/binary>>} ->
            {ok, Data};
        {reply, <<"E", Data/binary>>} ->
            {error, binary_to_list(Data)}
    end.

gosecrets_loop(Port, Parent) ->
    receive
        {call, Msg} ->
            Port ! {self(), {command, encode(Msg)}},
            receive
                Exit = {'EXIT', _, _} ->
                    gosecret_process_exit(Port, Exit);
                {Port, {data, Data}} ->
                    Parent ! {reply, Data}
            end,
            gosecrets_loop(Port, Parent);
        Exit = {'EXIT', _, _} ->
            gosecret_process_exit(Port, Exit)
    end.

gosecret_process_exit(Port, Exit) ->
    ?log_debug("Received exit ~p for port ~p", [Exit, Port]),
    gosecret_do_process_exit(Port, Exit).

gosecret_do_process_exit(Port, {'EXIT', Port, Reason}) ->
    exit({port_terminated, Reason});
gosecret_do_process_exit(_Port, {'EXIT', _, Reason}) ->
    exit(Reason).

encode({set_password, Password}) ->
    BinaryPassoword = list_to_binary(Password),
    <<1, BinaryPassoword/binary>>;
encode(create_data_key) ->
    <<2>>;
encode({set_data_key, DataKey}) ->
    <<3, DataKey/binary>>;
encode(get_data_key) ->
    <<4>>;
encode({encrypt, Data}) ->
    <<5, Data/binary>>;
encode({decrypt, Data}) ->
    <<6, Data/binary>>.
