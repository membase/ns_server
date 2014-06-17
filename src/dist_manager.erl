%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
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
%% Distributed erlang configuration and management
%%
-module(dist_manager).

-behaviour(gen_server).

-include("ns_common.hrl").

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([adjust_my_address/2, read_address_config/0, save_address_config/2,
         ip_config_path/0, using_user_supplied_address/0, reset_address/0]).

-record(state, {self_started,
                user_supplied,
                my_ip}).

-define(WAIT_FOR_ADDRESS_ATTEMPTS, 10).
-define(WAIT_FOR_ADDRESS_SLEEP, 1000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ip_config_path() ->
    path_config:component_path(data, "ip").

ip_start_config_path() ->
    path_config:component_path(data, "ip_start").

using_user_supplied_address() ->
    gen_server:call(?MODULE, using_user_supplied_address).

reset_address() ->
    gen_server:call(?MODULE, reset_address).

strip_full(String) ->
    String2 = string:strip(String),
    String3 = string:strip(String2, both, $\n),
    String4 = string:strip(String3, both, $\r),
    case String4 =:= String of
        true ->
            String4;
        _ ->
            strip_full(String4)
    end.

read_address_config() ->
    IpStartPath = ip_start_config_path(),
    case read_address_config_from_path(IpStartPath) of
        Address when is_list(Address) ->
            {Address, true};
        read_error ->
            read_error;
        undefined ->
            IpPath = ip_config_path(),
            case read_address_config_from_path(IpPath) of
                Address when is_list(Address) ->
                    {Address, false};
                Other ->
                    Other
            end
    end.

read_address_config_from_path(Path) ->
    ?log_info("Reading ip config from ~p", [Path]),
    case file:read_file(Path) of
        {ok, BinaryContents} ->
            case strip_full(binary_to_list(BinaryContents)) of
                "" ->
                    undefined;
                V ->
                    V
            end;
        {error, enoent} ->
            undefined;
        {error, Error} ->
            ?log_error("Failed to read ip config from `~s`: ~p",
                       [Path, Error]),
            read_error
    end.

wait_for_address(Address) ->
    wait_for_address(Address, ?WAIT_FOR_ADDRESS_ATTEMPTS).

wait_for_address(_Address, 0) ->
    bad_address;
wait_for_address(Address, N) ->
    case misc:is_good_address(Address) of
        ok ->
            ok;
        {address_not_allowed, Message}  ->
            ?log_error("Desired address ~s is not allowed by erlang: ~s", [Address, Message]),
            bad_address;
        Other ->
            case Other of
                {cannot_resolve, Errno} ->
                    ?log_warning("Could not resolve address `~s`: ~p",
                                 [Address, Errno]);
                {cannot_listen, Errno} ->
                    ?log_warning("Cannot listen on address `~s`: ~p",
                                 [Address, Errno])
            end,

            ?log_info("Configured address `~s` seems to be invalid. "
                      "Giving OS a chance to bring it up.", [Address]),
            timer:sleep(?WAIT_FOR_ADDRESS_SLEEP),
            wait_for_address(Address, N - 1)
    end.

save_address_config(State, UserSupplied) ->
    PathPair = [ip_start_config_path(), ip_config_path()],
    [Path, ClearPath] =
        case UserSupplied of
            true ->
                PathPair;
            false ->
                lists:reverse(PathPair)
        end,
    DeleteRV = file:delete(ClearPath),
    ?log_info("Deleting irrelevant ip file ~p: ~p", [ClearPath, DeleteRV]),
    ?log_info("saving ip config to ~p", [Path]),
    misc:atomic_write_file(Path, State#state.my_ip).

save_node(NodeName, Path) ->
    ?log_info("saving node to ~p", [Path]),
    misc:atomic_write_file(Path, NodeName ++ "\n").

save_node(NodeName) ->
    case application:get_env(nodefile) of
        {ok, undefined} -> nothing;
        {ok, NodeFile} -> save_node(NodeName, NodeFile);
        X -> X
    end.

init([]) ->
    net_kernel:stop(),

    {Address, UserSupplied} =
        case read_address_config() of
            undefined ->
                ?log_info("ip config not found. Looks like we're brand new node"),
                {"127.0.0.1", false};
            read_error ->
                ?log_error("Could not read ip config. "
                           "Will refuse to start for safety reasons."),
                ale:sync(?NS_SERVER_LOGGER),
                erlang:halt(1);
            V ->
                V
        end,

    case wait_for_address(Address) of
        ok ->
            ok;
        bad_address ->
            ?log_error("Configured address `~s` seems to be invalid. "
                       "Will refuse to start for safety reasons.", [Address]),
            ale:sync(?NS_SERVER_LOGGER),
            erlang:halt(1)
    end,

    {ok, bringup(Address, UserSupplied)}.

%% There are only two valid cases here:
%% 1. Successfully started
decode_status({ok, _Pid}) ->
    true;
%% 2. Already initialized (via -name or -sname)
decode_status({error, {{already_started, _Pid}, _Stack}}) ->
    false.

is_free_nodename(ShortName) ->
    {ok, Names} = erl_epmd:names({127,0,0,1}),
    not lists:keymember(ShortName, 1, Names).

wait_for_nodename(ShortName) ->
    wait_for_nodename(ShortName, 5).

wait_for_nodename(ShortName, Attempts) ->
    case is_free_nodename(ShortName) of
        true ->
            ok;
        false ->
            case Attempts of
                0 ->
                    {error, duplicate_name};
                _ ->
                    ?log_info("Short name ~s is still occupied. "
                              "Will try again after a bit", [ShortName]),
                    timer:sleep(500),
                    wait_for_nodename(ShortName, Attempts - 1)
            end
    end.

-spec adjust_my_address(string(), boolean()) ->
                               net_restarted | not_self_started | nothing |
                               {address_save_failed, term()}.
adjust_my_address(MyIP, UserSupplied) ->
    gen_server:call(?MODULE, {adjust_my_address, MyIP, UserSupplied}).

%% Bring up distributed erlang.
bringup(MyIP, UserSupplied) ->
    ShortName = misc:get_env_default(short_name, "ns_1"),
    MyNodeNameStr = ShortName ++ "@" ++ MyIP,
    MyNodeName = list_to_atom(MyNodeNameStr),

    ?log_info("Attempting to bring up net_kernel with name ~p", [MyNodeName]),
    ok = wait_for_nodename(ShortName),
    Rv = decode_status(net_kernel:start([MyNodeName, longnames])),
    net_kernel:set_net_ticktime(misc:get_env_default(set_net_ticktime, 60)),

    %% Rv can be false in case -name has been passed to erl but we still need
    %% to save the node name to be able to shutdown the server gracefully.
    ActualNodeName = erlang:atom_to_list(node()),
    RN = save_node(ActualNodeName),
    ?log_debug("Attempted to save node name to disk: ~p", [RN]),

    #state{self_started = Rv, my_ip = MyIP, user_supplied = UserSupplied}.

%% Tear down distributed erlang.
teardown() ->
    ok = net_kernel:stop().

do_adjust_address(MyIP, UserSupplied, State = #state{my_ip = MyOldIP}) ->
    {NewState, Status} =
        case MyOldIP of
            MyIP ->
                {State#state{user_supplied = UserSupplied}, nothing};
            _ ->
                Cookie = erlang:get_cookie(),
                teardown(),
                ?log_info("Adjusted IP to ~p", [MyIP]),
                NewState1 = bringup(MyIP, UserSupplied),
                if
                    NewState1#state.self_started ->
                        ?log_info("Re-setting cookie ~p", [{Cookie, node()}]),
                        erlang:set_cookie(node(), Cookie);
                    true -> ok
                end,
                {NewState1, net_restarted}
        end,

    case save_address_config(NewState, UserSupplied) of
        ok ->
            ?log_info("Persisted the address successfully"),
            {reply, Status, NewState};
        {error, Error} ->
            ?log_warning("Failed to persist the address: ~p", [Error]),
            {stop,
             {address_save_failed, Error},
             {address_save_failed, Error},
             State}
    end.


handle_call({adjust_my_address, _, _}, _From,
            #state{self_started = false} = State) ->
    {reply, not_self_started, State};
handle_call({adjust_my_address, "127.0.0.1", true = _UserSupplied}, From, State) ->
    handle_call({adjust_my_address, "127.0.0.1", false}, From, State);
handle_call({adjust_my_address, _MyIP, false = _UserSupplied}, _From,
            #state{user_supplied = true} = State) ->
    {reply, nothing, State};
handle_call({adjust_my_address, MyOldIP, UserSupplied}, _From,
            #state{my_ip = MyOldIP, user_supplied = UserSupplied} = State) ->
    {reply, nothing, State};
handle_call({adjust_my_address, MyIP, UserSupplied}, _From,
            State) ->
    do_adjust_address(MyIP, UserSupplied, State);

handle_call(using_user_supplied_address, _From,
            #state{user_supplied = UserSupplied} = State) ->
    {reply, UserSupplied, State};
handle_call(reset_address, _From,
            #state{self_started = true,
                   user_supplied = true} = State) ->
    ?log_info("Going to mark current user-supplied address as non-user-supplied address"),
    NewState = State#state{user_supplied = false},
    case save_address_config(NewState, false) of
        ok ->
            ?log_info("Persisted the address successfully"),
            {reply, net_restarted, NewState};
        {error, Error} ->
            ?log_warning("Failed to persist the address: ~p", [Error]),
            {stop,
             {address_save_failed, Error},
             {address_save_failed, Error},
             State}
    end;
handle_call(reset_address, _From, State) ->
    {reply, net_restarted, State};
handle_call(_Request, _From, State) ->
    {reply, unhandled, State}.

handle_cast(_, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
