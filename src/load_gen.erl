%%
%% Copyright (c) 2007  Dustin Sallings <dustin@spy.net>
%%

-module(load_gen).

-export([start/1, start/3]).

-record(state, {has_more=true,
                feeder,
                result_processor,
                outstanding=0,
                requestors}).

start(Args) -> apply(?MODULE, start, Args).

% start(RequestorMod, BaseUrl, Filename, TimeTransform) ->
%     {ok, Feeder} =
%         http_file_reader:start_link(Filename, BaseUrl,
%                                     my_to_float(TimeTransform), self()),
%     {ok, ResultProcessor} =
%         http_response_processor:start_link(),
%
%     start(RequestorMod, Feeder, ResultProcessor).
%
% my_to_float(S) ->
% 	case catch(list_to_float(S)) of
% 		{'EXIT', {badarg, _Stuff}} ->
% 			list_to_integer(S) * 1.0;
% 		X -> X
% 	end.

start(RequestorMod, Feeder, ResultProcessor) ->
	process_flag(trap_exit, true),

    % Requires a .hosts.erlang file.
    World = [net_adm:world()],
	error_logger:info_msg("world:  ~p~n", World),

	Requestors = start_requestors(RequestorMod, nodes(known)),
	error_logger:info_msg(
		"Feeder: ~p.~nRequestors: ~p.~nResult Processor: ~p.~n",
		[Feeder, Requestors, ResultProcessor]),

	% Do main loop
	loop(#state{feeder=Feeder,
                result_processor=ResultProcessor,
                requestors=queue:from_list(Requestors)}),

	% Clean stuff up
	ResultProcessor ! done,
	lists:foreach(fun(P) -> P ! done end, Requestors),

	error_logger:info_msg("Processing is complete.~n", []).

% Load our latest code on all of the nodes and start them up.
start_requestors(RequestorMod, Nodes) ->
	% First, load the code
	{RequestorMod, Bin, File} = code:get_object_code(RequestorMod),
	OtherNodes = lists:filter(fun(N) -> N =/= node() end,
                              Nodes),
	error_logger:info_msg("Loading code on:  ~p~n", [OtherNodes]),
	{LoadBinaryReplies, _} = rpc:multicall(OtherNodes, code, load_binary,
                                           [RequestorMod, File, Bin]),

	% Validate the multicall
	lists:foreach(fun({module, RequestorMod2}) ->
                      RequestorMod2 = RequestorMod,
                      ok
                  end,
                  LoadBinaryReplies),
	error_logger:info_msg("Loaded code:  ~p~n", [LoadBinaryReplies]),

	% OK, code is loaded, start the service
	lists:map(fun(N) -> spawn_link(N, RequestorMod, init, []) end,
              Nodes).

queue_another(State, Req) ->
	{{value, Requestor}, Q2} = queue:out(State#state.requestors),
	Requestor ! {request, self(), Req},
	State#state{outstanding = State#state.outstanding + 1,
                requestors = queue:in(Requestor, Q2)}.

still_going(State) ->
	State#state.has_more or (State#state.outstanding > 0).

loop(State) ->
	case still_going(State) of
		true ->
			% Have to save the feeder pid because I can't use the
			% record format in the receive block for some reason.
			Feeder=State#state.feeder,
			receive
				input_complete ->
					loop(State#state{has_more=false});
				{request, Req} ->
					loop(queue_another(State, Req));
				{response, Node, QLen, ProcessTime, Req, Result} ->
					State#state.result_processor !
						{result,
                         State#state.outstanding,
                         Node, QLen, ProcessTime, Req, Result},
					loop(State#state{outstanding = State#state.outstanding - 1});
				{'EXIT', Feeder, Reason } ->
					error_logger:info_msg("Feeder exited: ~p~n", [Reason]),
					loop(State#state{has_more=false});
				Unknown ->
					error_logger:error_msg("Unknown message: ~p~n", [Unknown])
			end;
		_ -> true
	end.
