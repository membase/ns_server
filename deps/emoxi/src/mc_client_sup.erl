-module(mc_client_sup).

-behaviour(supervisor).

%% API
-export([start_link/3, start_child/2]).

%% Supervisor callbacks
-export([init/1, start_session/4]).

start_link(ProtocolModule, ProcessorModule, ProcessorEnv) ->
    supervisor:start_link(?MODULE,
                          [ProtocolModule, ProcessorModule, ProcessorEnv]).

init(Args) ->
    SupFlags = {simple_one_for_one, 1, 1},

    Restart = temporary,
    Shutdown = 2000,
    Type = worker,

    ChildTmpl = {undefined, {?MODULE, start_session, Args},
                 Restart, Shutdown, Type, ['AModule']},

    {ok, {SupFlags, [ChildTmpl]}}.

start_child(SupervisorRef, NS) ->
    {ok, Child} = supervisor:start_child(SupervisorRef, [NS]),
    gen_tcp:controlling_process(NS, Child),
    Child ! go.

% Accept incoming connections.
start_session(ProtocolModule, ProcessorModule, ProcessorEnv, NS) ->
    Pid = spawn_link(fun() ->
                             receive go -> ok end,
                             new_session(NS, ProtocolModule,
                                         ProcessorModule, ProcessorEnv)
                     end),
    {ok, Pid}.

new_session(NS, ProtocolModule, ProcessorModule, ProcessorEnv) ->
    case ProcessorModule:session(NS, ProcessorEnv) of
        {ok, _, Session} ->
            Outpid = spawn_link(ProtocolModule,
                                loop_out, [NS]),
            ProtocolModule:loop_in(NS, Outpid, 1,
                                   ProcessorModule,
                                   Session);
        Error ->
            ns_log:log(?MODULE, 0001, "could not start session: ~p",
                       [Error]),
            gen_tcp:close(NS)
    end.
