%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

% Distributed erlang configuration and management

-module(dist_manager).

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([adjust_my_address/1, read_address_config/0, save_address_config/1, ip_config_path/0]).

-record(state, {self_started, my_ip}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

ip_config_path() ->
    %% this smells bad, but we live higher on supervisor/process
    %% hierarchy than ns_config, so I see no other way
    {ok, CfgPath} = application:get_env(ns_server, ns_server_config),
    Path = filename:dirname(CfgPath),
    filename:join(Path, "ip").

read_address_config() ->
    Path = ip_config_path(),
    error_logger:info_msg("reading ip config from ~p~n", [Path]),
    case file:read_file(Path) of
        {ok, BinaryContents} ->
            AddrString = string:strip(binary_to_list(BinaryContents)),
            case inet:getaddr(AddrString, inet) of
                {error, Errno1} ->
                    error_logger:error_msg("Got error:~p. Ignoring bad address:~s~n", [Errno1, AddrString]),
                    undefined;
                {ok, IpAddr} ->
                    case gen_tcp:listen(0, [inet, {ip, IpAddr}]) of
                        {error, Errno2} ->
                            error_logger:error_msg("Got error:~p. Cannot listen on configured address:~s~n", [Errno2, AddrString]),
                            undefined;
                        {ok, Socket} ->
                            gen_tcp:close(Socket),
                            AddrString
                    end
            end;
        _ -> undefined
    end.

save_address_config(State) ->
    Path = ip_config_path(),
    error_logger:info_msg("saving ip config to ~p~n", [Path]),
    TmpPath = Path ++ ".tmp",
    case file:write_file(TmpPath, State#state.my_ip) of
        ok ->
            file:rename(TmpPath, Path);
        X -> X
    end.

init([]) ->
    InitialAddr = case read_address_config() of
                      undefined -> "127.0.0.1";
                      X -> X
                  end,
    {ok, bringup(InitialAddr)}.

%% There are only two valid cases here:
%% 1. Successfully started
decode_status({ok, _Pid}) ->
    true;
%% 2. Already initialized (via -name or -sname)
decode_status({error, {{already_started, _Pid}, _Stack}}) ->
    false.

adjust_my_address(MyIP) ->
    gen_server:call(?MODULE, {adjust_my_address, MyIP}).

%% Bring up distributed erlang.
bringup(MyIP) ->
    MyNodeName = list_to_atom("ns_1@" ++ MyIP),
    Rv = decode_status(net_kernel:start([MyNodeName, longnames])),
    #state{self_started = Rv, my_ip = MyIP}.

%% Tear down distributed erlang.
teardown() ->
    ok = net_kernel:stop().

handle_call({adjust_my_address, MyIP}, _From,
            #state{self_started = true, my_ip = MyOldIP} = State) ->
    case MyIP =:= MyOldIP of
        true -> {reply, nothing, State};
        false -> Cookie = erlang:get_cookie(),
                 teardown(),
                 error_logger:info_msg("Adjusted IP to ~p~n", [MyIP]),
                 NewState = bringup(MyIP),
                 if
                     NewState#state.self_started ->
                         error_logger:info_msg("Re-setting cookie ~p~n", [{Cookie, node()}]),
                         erlang:set_cookie(node(), Cookie);
                     true -> ok
                 end,

                 RV = save_address_config(NewState),
                 error_logger:info_msg("save_address_config: ~p~n", [RV]),
                 {reply, net_restarted, NewState}
    end;
handle_call({adjust_my_address, _}, _From,
            #state{self_started = false} = State) ->
    {reply, nothing, State};
handle_call(_Request, _From, _State) ->
    exit(unhandled).

handle_cast(_, _State) ->
    exit(unhandled).

handle_info(_Info, _State) ->
    exit(unhandled).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
