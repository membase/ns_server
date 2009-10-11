-module(mc_handler_hashtable).

% gen_server defines most of the interface for this module.
-behaviour (gen_server).

-include("mc_constants.hrl").

-export([start_link/0, terminate/2, handle_info/2, code_change/3]).
-export([init/1, handle_call/3, handle_cast/2]).

-record(cached_item, {
          flags=0,
          cas=0,
          data
         }).

-record(mc_state, {cas=0, store=dict:new()}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

code_change(_OldVsn, State, _Extra) ->
    error_logger:info_msg("Code's changing.~n", []),
    {ok, State}.

init(_Args) ->
    {ok, #mc_state{}}.

terminate(shutdown, State) ->
    {ok, State}.

handle_info(flush, _State) ->
    error_logger:info_msg("Doing delayed flush.~n", []),
    {noreply, #mc_state{}};
handle_info({delete_if, Key, Cas}, State) ->
    case dict:find(Key, State#mc_state.store) of
        {ok, #cached_item{cas=Cas}} ->
            error_logger:info_msg("Doing expiry of ~p.~n", [Key]),
            {noreply, State#mc_state{store=dict:erase(Key,
                                                     State#mc_state.store)}};
        _ ->
            error_logger:info_msg("Not doing expiry of ~p.~n", [Key]),
            {noreply, State}
    end;

handle_info(X, State) ->
    error_logger:info_msg("Someone asked for info ~p~n", [X]),
    {noreply, State}.

handle_cast(X, Locks) ->
    error_logger:info_msg("Someone casted ~p~n", [X]),
    {noreply, Locks}.

% Utility stuff

schedule_expiry(0, _Key, _Cas) -> ok;
schedule_expiry(Expiration, Key, Cas) ->
    erlang:send_after(Expiration * 1000, self(), {delete_if, Key, Cas}).

% Actual protocol handling goes below.

% Immediate flush
handle_call({?FLUSH, <<0:32>>, <<>>, <<>>, _CAS}, _From, _State) ->
    error_logger:info_msg("Got immediate flush command.~n", []),
    {reply, #mc_response{}, #mc_state{}};
% Delayed flush
handle_call({?FLUSH, <<Delay:32>>, <<>>, <<>>, _CAS}, _From, State) ->
    error_logger:info_msg("Got flush command delayed for ~p.~n", [Delay]),
    erlang:send_after(Delay * 1000, self(), flush),
    {reply, #mc_response{}, State};
% GET operation
handle_call({?GET, <<>>, Key, <<>>, _CAS}, _From, State) ->
    error_logger:info_msg("Got GET command for ~p.~n", [Key]),
    case dict:find(Key, State#mc_state.store) of
        {ok, Item} ->
            Flags = Item#cached_item.flags,
            FlagsBin = <<Flags:32>>,
            {reply,
             #mc_response{extra=FlagsBin,
                          cas=Item#cached_item.cas,
                          body=Item#cached_item.data},
             State};
        _ ->
            {reply, #mc_response{status=1, body="Does not exist"}, State}
    end;
% SET operation
handle_call({?SET, <<Flags:32, Expiration:32>>, Key, Value, _CAS},
            _From, State) ->
    error_logger:info_msg("Got SET command for ~p.~n", [Key]),
    NewCas = State#mc_state.cas + 1,
    schedule_expiry(Expiration, Key, NewCas),
    {reply,
     #mc_response{cas=NewCas},
     State#mc_state{cas=NewCas,
                    store=dict:store(Key,
                                     #cached_item{flags=Flags,
                                                  cas=NewCas,
                                                  data=Value},
                                     State#mc_state.store)}};
% Unknown commands.
handle_call({_OpCode, _Header, _Key, _Body, _CAS}, _From, State) ->
    {reply,
     #mc_response{status=?UNKNOWN_COMMAND, body="Unknown command"},
     State}.

