-module(mc_handler_hashtable).

% gen_server defines most of the interface for this module.
-behaviour (gen_server).

-include("mc_constants.hrl").

-export([start_link/0, terminate/2, handle_info/2, code_change/3]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(cached_item, {
          flags=0,
          data
         }).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

code_change(_OldVsn, State, _Extra) ->
    error_logger:info_msg("Code's changing.~n", []),
    {ok, State}.

init(_Args) ->
    {ok, dict:new()}.

terminate(shutdown, State) ->
    {ok, State}.

handle_info(flush, _State) ->
    error_logger:info_msg("Doing delayed flush.~n", []),
    {noreply, dict:new()};
handle_info(X, State) ->
    error_logger:info_msg("Someone asked for info ~p~n", [X]),
    {noreply, State}.

handle_cast(X, Locks) ->
    error_logger:info_msg("Someone casted ~p~n", [X]),
    {noreply, Locks}.

% Actual protocol handling goes below.

% Immediate flush
handle_call({?FLUSH, <<0:32>>, <<>>, <<>>, _CAS}, _From, _State) ->
    error_logger:info_msg("Got immediate flush command.~n", []),
    {reply, {0, <<>>, <<>>, <<>>, 0}, dict:new()};
% Delayed flush
handle_call({?FLUSH, <<Delay:32>>, <<>>, <<>>, _CAS}, _From, State) ->
    error_logger:info_msg("Got flush command delayed for ~p.~n", [Delay]),
    erlang:send_after(Delay * 1000, self(), flush),
    {reply, {0, <<>>, <<>>, <<>>, 0}, State};
% GET operation
handle_call({?GET, <<>>, Key, <<>>, _CAS}, _From, State) ->
    error_logger:info_msg("Got GET command for ~p.~n", [Key]),
    case dict:find(Key, State) of
        {ok, Item} ->
            Flags = Item#cached_item.flags,
            {reply, {0, <<Flags:32>>, <<>>, Item#cached_item.data, 0},
             State};
        _ ->
            {reply, {1, <<>>, <<>>, <<"Does not exist">>, 0}, State}
    end;
% SET operation
handle_call({?SET, <<Flags:32, _Expiration:32>>, Key, Value, _CAS},
            _From, State) ->
    error_logger:info_msg("Got SET command for ~p.~n", [Key]),
    % TODO:  Generate a CAS, call a future delete with that CAS, etc...
    {reply,
     {0, <<>>, <<>>, <<>>, 0},
     dict:store(Key, #cached_item{flags=Flags, data=Value}, State)};
% Unknown commands.
handle_call({_OpCode, _Header, _Key, _Body, _CAS}, _From, State) ->
    {reply, {?UNKNOWN_COMMAND, <<>>, <<>>, <<"Unknown command">>, 0}, State}.


