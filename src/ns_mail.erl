-module(ns_mail).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([send/5, ns_log_cat/1]).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    {ok, empty_state}.

handle_call(Request, From, State) ->
    error_logger:info_msg("ns_mail: unexpected call ~p from ~p~n",
                          [Request, From]),
    {ok, State}.

handle_cast({send, Sender, Rcpts, Body, Options}, State) ->
    error_logger:info_msg("ns_mail: sending email ~p ~p ~p~n",
                          [Sender, Rcpts, Body]),
    gen_smtp_client:send({Sender, Rcpts, Body}, Options),
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    case Reason of
        normal ->
            error_logger:info_msg("ns_mail: successfully sent mail~n");
        Error ->
            ns_log:log(?MODULE, 0001, "error sending mail: ~p",
                           [Error])
    end,
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% API

send(Sender, Rcpts, Subject, Body, Options) ->
    Message = mimemail:encode({<<"text">>, <<"plain">>,
                              make_headers(Sender, Rcpts, Subject), [],
                              list_to_binary(Body)}),
    gen_server:cast({global, ?MODULE},
                    {send, Sender, Rcpts,
                     binary_to_list(Message),
                     Options}).

ns_log_cat(0001) -> warn.

%% Internal functions

format_addr(Addr) ->
    "<" ++ Addr ++ ">".

make_headers(Sender, Rcpts, Subject) ->
    [{<<"From">>, list_to_binary(format_addr(Sender))},
     {<<"To">>, list_to_binary(string:join(lists:map(fun format_addr/1, Rcpts), ", "))},
     {<<"Subject">>, list_to_binary(Subject)}].
