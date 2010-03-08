%% @author Northscale <info@northscale.com>
%% @copyright 2010 NorthScale, Inc.
%% All rights reserved.

-module(stats_aggregator).

-behaviour(gen_server).

-define(SAMPLE_SIZE, 1800).

%% API
-export([start_link/0,
         received_data/5,
         received_topkeys/5,
         get_stats/4,
         get_stats/3,
         get_stats/2,
         get_stats/1,
         get_topkeys/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {vals, topkeys}).

start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

init([]) ->
    timer:send_interval(60000, garbage_collect),
    {ok, #state{vals=dict:new(), topkeys=dict:new()}}.

handle_call({get, Hostname, Port, Bucket, Count}, _From, State) ->
    Reply = (catch {ok, ringdict:to_dict(Count,
                             dict:fetch({Hostname, Port, Bucket},
                                        State#state.vals))}),
    {reply, Reply, State};
handle_call({get, Hostname, Port, Count}, _From, State) ->
    Reply =
        (catch {ok, dict:fold(
                 fun ({H, P, _B}, V, A) ->
                         case {H, P} of
                             {Hostname, Port} ->
                                 combine_stats(Count, V, A);
                             _ -> A
                         end
                 end,
                 dict:new(),
                 State#state.vals)}),
    {reply, Reply, State};
handle_call({get, Bucket, Count}, _From, State) ->
    Reply =
        (catch {ok, dict:fold(
                 fun ({_H, _P, B}, V, A) ->
                         case B of
                             Bucket ->
                                 combine_stats(Count, V, A);
                             _ -> A
                         end
                 end,
                 dict:new(),
                 State#state.vals)}),
    {reply, Reply, State};
handle_call({get, Count}, _From, State) ->
    Reply =
        (catch {ok, dict:fold(
                 fun ({_H, _P, _B}, V, A) ->
                         combine_stats(Count, V, A)
                 end,
                 dict:new(),
                 State#state.vals)}),
    {reply, Reply, State};
handle_call({get_topkeys, Bucket}, _From, State) ->
    Reply = (catch {ok, dict:fold(
            fun ({_Host, _Port, B}, Dict, Acc)->
                    case B of
                        Bucket ->
                            dict:merge(
                                fun (_Key, Value1, _Value2) ->
                                        Value1
                                end,
                                Dict, Acc);
                        _ -> Acc
                    end
            end,
            dict:new(),
            State#state.topkeys)}),
    {reply, Reply, State}.

handle_cast({received, T, Hostname, Port, Bucket, Stats}, State) ->
    TS = dict:store(t, T, Stats),
    {noreply, State#state{vals=dict:update({Hostname, Port, Bucket},
                                           fun(R) ->
                                                   ringdict:add(TS, R)
                                           end,
                                           ringdict:new(?SAMPLE_SIZE),
                                           State#state.vals),
                           topkeys=State#state.topkeys}};
handle_cast({received_topkeys, _T, Hostname, Port, Bucket, Topkeys}, State) ->
    {noreply, State#state{vals=State#state.vals,
                          topkeys=dict:store({Hostname, Port, Bucket},
                                          Topkeys,
                                          State#state.topkeys)}}.

handle_info(garbage_collect, State) ->
    {BucketConfigs, Servers} = mc_pool:get_buckets_and_servers(),
    Buckets = lists:map(fun({K, _V}) -> K end, BucketConfigs),
    OldVals = State#state.vals,
    Vals = dict:filter(fun({H, P, B}, _V) ->
                           lists:member(B, Buckets) and
                               lists:member({H, P}, Servers)
                       end, OldVals),
    OldTopkeys = State#state.topkeys,
    Topkeys = dict:filter(fun({H, P, B}, _V) ->
                              lists:member(B, Buckets) and
                                  lists:member({H, P}, Servers)
                          end, OldTopkeys),
    {noreply, State#state{vals=Vals, topkeys=Topkeys}};
handle_info(Info, State) ->
    error_logger:info_msg("Just received ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

combine_stats(N, New, Existing) ->
    dict:merge(fun val_sum/3, dict:map(fun (_K, V) ->
                                       lists:map(fun to_int/1, V) end,
               dict:filter(fun (K, _V) -> classify(K) end,
                           ringdict:to_dict(N, New, true))),
               Existing).

to_int(empty) -> 0;
to_int(X) when is_list(X) -> list_to_integer(X);
to_int(X) when is_integer(X) -> X;
to_int(X = {_, _, _}) -> misc:time_to_epoch_ms_int(X).

val_sum(t, empty, L2) -> L2;
val_sum(t, L1, _L2) -> L1;
val_sum(_K, L1, L2) ->
    % TODO: Need a better zipwith if L1 and L2's aren't the same length,
    % which could happen if a new server appears and its list is short.
    lists:zipwith(fun(V1, V2) -> V1 + V2 end, L1, L2).

classify("pid") -> false;
classify("uptime") -> false;
classify("time") -> false;
classify("version") -> false;
classify("pointer_size") -> false;
classify("rusage_user") -> false;
classify("rusage_system") -> false;
classify("tcpport") -> false;
classify("udpport") -> false;
classify("inter") -> false;
classify("verbosity") -> false;
classify("oldest") -> false;
classify("domain_socket") -> false;
classify("umask") -> false;
classify("growth_factor") -> false;
classify("chunk_size") -> false;
classify("num_threads") -> false;
classify("stat_key_prefix") -> false;
classify("detail_enabled") -> false;
classify("reqs_per_event") -> false;
classify("cas_enabled") -> false;
classify("tcp_backlog") -> false;
classify("binding_protocol") -> false;
classify(_) -> true.

%
% API
%

received_data(T, Hostname, Port, Bucket, Stats) ->
    gen_server:cast({global, ?MODULE}, {received, T, Hostname, Port, Bucket, Stats}).

received_topkeys(T, Hostname, Port, Bucket, Topkeys) ->
    gen_server:cast({global, ?MODULE}, {received_topkeys, T, Hostname, Port, Bucket, Topkeys}).

get_stats(Hostname, Port, Bucket, Count) ->
    gen_server:call({global, ?MODULE}, {get, Hostname, Port, Bucket, Count}).

get_stats(Hostname, Port, Count) ->
    gen_server:call({global, ?MODULE}, {get, Hostname, Port, Count}).

get_stats(Bucket, Count) ->
    gen_server:call({global, ?MODULE}, {get, Bucket, Count}).

get_stats(Count) ->
    gen_server:call({global, ?MODULE}, {get, Count}).

get_topkeys(Bucket) ->
    gen_server:call({global, ?MODULE}, {get_topkeys, Bucket}).

