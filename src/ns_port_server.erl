% Copyright (c) 2010, NorthScale, Inc.
% All rights reserved.

-module(ns_port_server).

-behavior(gen_server).

%% API
-export([start_link/4, params/1,
         get_port_server_config/1,
         get_port_server_config/2,
         get_port_server_config/3,
         get_port_server_param/3,
         get_port_server_param/4,
         set_port_server_config/3,
         set_port_server_param/4,
         set_port_server_param/5,
         find_param/2,
         set_param/3]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-include_lib("eunit/include/eunit.hrl").

%% Server state
-record(state, {port, name, params}).

% ----------------------------------------------

start_link(Name, Cmd, Args, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE,
                          {Name, Cmd, Args, Opts}, []).

params(Pid) ->
    gen_server:call(Pid, params).

% The key/value in ns_config will look somewhat like...
%
% {port_servers,
%   [{memcached, "./memcached",
%     ["-E", "engines/default_engine.so",
%      "-p", "11212"
%      ],
%     [{env, [{"MEMCACHED_CHECK_STDIN", "thread"}]}]
%    }
%   ]
% }.
%
% Or, the key might actually be a {node, node(), port_servers} tuple, like...
%
% {{node, 'ns_1@foo.bar.com', port_servers}, ...}

get_port_server_config(PortName) ->
    get_port_server_config(ns_config:get(), PortName).

get_port_server_config(Config, PortName) ->
    get_port_server_config(Config, PortName, node()).

get_port_server_config(Config, PortName, Node) ->
    case ns_config:search_prop_tuple(Config, {node, Node, port_servers},
                                     PortName, false) of
        false -> ns_config:search_prop_tuple(Config, port_servers,
                                             PortName);
        Tuple -> Tuple
    end.

set_port_server_config(Config, PortServerName, PortConfig) ->
    PortServers = case ns_config:search(Config, port_servers) of
                      {value, X} -> X;
                      _          -> []
                  end,
    ns_config:set(port_servers,
                  lists:keystore(PortServerName, 1, PortServers, PortConfig)).

get_port_server_param(Config, PortServerName, ParameterName) ->
    get_port_server_param(Config, PortServerName, ParameterName, node()).

get_port_server_param(Config, PortServerName, ParameterName, Node) ->
    StartArgs =
        case get_port_server_config(Config, PortServerName, Node) of
            undefined -> [];
            {PortServerName, _Path, S}       -> S;
            {PortServerName, _Path, S, _Env} -> S
        end,
    find_param(ParameterName, StartArgs).

set_port_server_param(Config, PortServerName, ParameterName, V) ->
    set_port_server_param(Config, PortServerName, ParameterName, V, node()).

set_port_server_param(Config, PortServerName, ParameterName, V, Node) ->
    {Path, StartArgs, Env} =
        case get_port_server_config(Config, PortServerName, Node) of
            {PortServerName, P, S}    -> {P, S, []};
            {PortServerName, P, S, E} -> {P, S, E}
        end,
    StartArgs2 = set_param(ParameterName, StartArgs, V),
    set_port_server_config(Config, PortServerName,
                           {PortServerName, Path, StartArgs2, Env}).

find_param(_, [])              -> false;
find_param(_, [_])             -> false;
find_param(X, [X, Val | _])    -> {value, Val};
find_param(X, [_, Val | Rest]) -> find_param(X, [Val | Rest]).

set_param(X, A, V) -> set_param(X, A, V, []).

set_param(X, [], NewVal, Acc) -> lists:reverse([NewVal, X | Acc]);
set_param(X, [X, _OldVal | Rest], NewVal, Acc) ->
    lists:reverse(Acc) ++ [X, NewVal | Rest];
set_param(X, [Y | Rest], NewVal, Acc) ->
    set_param(X, Rest, NewVal, [Y | Acc]).

% ----------------------------------------------

init({Name, _Cmd, _Args, _Opts} = Params) ->
    Port = open_port(Params),
    case is_port(Port) of
        true  -> {ok, #state{port = Port, name = Name, params = Params}};
        false -> ns_log:log(?MODULE, 0001, "could not start process: ~p",
                            [Params]),
                 {stop, Port}
    end.

open_port({Name, Cmd, ArgsIn, Opts}) ->
    Args = case os:getenv("NS_PORT_SERVER_ARGS_" ++ atom_to_list(Name)) of
               false -> ArgsIn;
               Any -> Y = string:tokens(Any, " "),
                      error_logger:info_msg(
                        "NS_PORT_SERVER_ARGS_~p override: ~p~n",
                        [Name, Y]),
                      Y
           end,
    {ok, Pwd} = file:get_cwd(),
    PrivDir = filename:join(Pwd, "priv"),
    FullPath = filename:join(PrivDir, Cmd),
    error_logger:info_msg("port server starting: ~p in ~p with ~p / ~p~n",
                          [FullPath, PrivDir, Args, Opts]),
    process_flag(trap_exit, true),
    open_port({spawn_executable, FullPath},
              [{args, Args},
               {cd, PrivDir}] ++ Opts).

handle_info({'EXIT', _Port, Reason}, State) ->
    error_logger:info_msg("port server (~p) exited: ~p~n",
                          [State#state.name, Reason]);
handle_info(Something, State) ->
    error_logger:info_msg("Got unexpected message while monitoring ~p: ~p~n",
                          [State#state.name, Something]),
    {stop, Something, State}.

handle_call(params, _From, #state{params = Params} = State) ->
    {reply, {ok, Params}, State};

handle_call(Something, _From, State) ->
    error_logger:info_msg("Unexpected call: ~p~n", [Something]),
    {reply, error, State}.

handle_cast(Something, State) ->
    error_logger:info_msg("Unexpected cast: ~p~n", [Something]),
    {noreply, State}.

terminate(normal, State) ->
    error_logger:info_msg("port server terminating ~p: ~p~n",
                          [State#state.name, normal]),
    ok;
terminate({port_exited, normal}, State) ->
    error_logger:info_msg("port server terminating ~p: port exited~n",
                          [State#state.name]),
    ok;
terminate(Reason, State) ->
    error_logger:info_msg("port server terminating ~p: ~p~n",
                          [State#state.name, Reason]),
    true = port_close(State#state.port).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% ----------------------------------------------

find_param_test() ->
    ?assertEqual({value, "11212"},
                 find_param("-p", ["-E", "foo",
                                   "-p", "11212"])),
    ?assertEqual({value, "11212"},
                 find_param("-p", ["-p", "11212",
                                   "-E", "foo"])),
    ?assertEqual({value, "11212"},
                 find_param("-p", ["-p", "11212"])),
    ?assertEqual(false,
                 find_param("-p", ["-p"])),
    ok.

set_param_test() ->
    ?assertEqual(["-E", "foo", "-p", "11212"],
                 set_param("-p", ["-E", "foo"],
                           "11212")),
    ?assertEqual(["-p", "11212"],
                 set_param("-p", [],
                           "11212")),
    ?assertEqual(["-p", "11212", "-E", "foo"],
                 set_param("-p", ["-p", "11211",
                                  "-E", "foo"],
                           "11212")),
    ?assertEqual(["-a", "hello", "-p", "11212", "-E", "foo"],
                 set_param("-p", ["-a", "hello",
                                  "-p", "11211",
                                  "-E", "foo"],
                           "11212")),
    ok.
