-module(menelaus_web_alerts_srv).

-behaviour(gen_server).
-define(SERVER, ?MODULE).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% @doc Hold client state for any alerts that need to be shown in
%% the browser, is used by menelaus_web to piggy back for a transport
%% until a long polling transport is used, will be single user
%% until then, many checks for alerts every ?SAMPLE_RATE milliseconds

-record(state, {messages, history, opaque}).

%% Amount of time to wait between state checks (ms)
-define(SAMPLE_RATE, 3000).

%% Amount of time between sending users the same alert (s)
-define(ALERT_TIMEOUT, 60 * 2).

-export([start_link/0, stop/0, add_alert/2, fetch_alerts/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% @doc Add an alert to be shown in the browser
-spec add_alert(atom(), binary()) -> ok.
add_alert(Key, Val) ->
    gen_server:call(?MODULE, {add_alert, Key, Val}).


%% @doc fetch a list of binary string, clearing out the message
%% history
-spec fetch_alerts() -> list(binary()).
fetch_alerts() ->
    gen_server:call(?MODULE, fetch_alert).


stop() ->
    gen_server:cast(?MODULE, stop).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    start_timer(),
    %start_subscriptions(),
    {ok, #state{messages=[], history=[], opaque=dict:new()}}.


handle_call(fetch_alert, _From, #state{history=Hist, messages=Msgs} = State) ->
    Alerts = [Msg || {_Key, Msg, _Time} <- Msgs],
    {reply, Alerts, State#state{history = Hist ++ Msgs, messages = []}};

handle_call({add_alert, Key, Val}, _From, #state{messages=Msgs} = State) ->
    {reply, ok, State#state{messages=[{Key, Val, misc:now_int()} | Msgs]}};

handle_call(_Request, _From, State) ->
    {reply, ok, State}.


handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(check_alerts, State) ->
    #state{messages=Msgs, history=Hist, opaque=Opaque} = State,
    {NewDict, NewAlerts} = check_alerts(Opaque, Hist),
    {noreply, State#state{
                opaque = NewDict,
                history = expire_history(Hist),
                messages = Msgs ++ NewAlerts
               }};

handle_info(_Info, State) ->
    {noreply, State}.


terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @doc Remind myself to check the alert status
start_timer() ->
    timer:send_interval(?SAMPLE_RATE, check_alerts).


%% @doc Accumulate various alerts, maintain a state dictionary
check_alerts(Opaque, Hist) ->
    Fun = fun(X, {Dict, Alerts}) ->
                  case check(X, Dict, Hist) of
                      {NDict, ok} ->
                          {NDict, Alerts};
                      {NDict, Alert} ->
                          {NDict, [{X, Alert, misc:now_int()} | Alerts]}
                  end
          end,
    lists:foldl(Fun, {Opaque, []}, [oom, ip]).

%% TODO:
-spec check(atom(), any(), list(tuple())) ->
    {any(), ok | binary()}.
check(ip, Opaque, _History) ->
    {Opaque, ok};

%% @doc check for any oom errors an any bucket
check(oom, Opaque, History) ->
    New = sum_oom_errors(),
    case dict:is_key(oom, Opaque) of
        false ->
            {dict:store(oom, New, Opaque), ok};
        true ->
            Old = dict:fetch(oom, Opaque),
            Alert = case New > Old andalso not sent(oom, History) of
                        true ->
                            <<"Out of Memory">>;
                        false ->
                            ok
                    end,
            {dict:store(oom, New, Opaque), Alert}
    end.


%% @doc Check against server history to see if a message was sent
%% recently
-spec sent(atom(), list()) -> true | false.
sent(Key, Hist) ->
    is_tuple(lists:keyfind(Key, 1, Hist)).


%% @doc Sum of all oom errors on all buckets
-spec sum_oom_errors() -> integer().
sum_oom_errors() ->
    lists:sum([ bucket_oom_errors(Bucket)
                || Bucket <- ns_memcached:active_buckets() ]).


%% @doc Total count of oom errors on a bucket
-spec bucket_oom_errors(atom()) -> integer().
bucket_oom_errors(Bucket) ->
    {ep_oom_errors, X} = stats_archiver:latest(Bucket, minute, ep_oom_errors),
    X.


%% @doc Server keeps a list of messages to check against sending
%% the same message repeatedly
-spec expire_history(list()) -> list().
expire_history(Hist) ->
    Now = misc:now_int(),
    [ {Key, Msg, Time} ||
        {Key, Msg, Time} <- Hist, Now - Time < ?ALERT_TIMEOUT ].


%% Cant currently test the alert timeouts as would need to mock
%% calls to the archiver
-include_lib("eunit/include/eunit.hrl").

basic_test_() ->
    {setup,
     fun() -> ?MODULE:start_link() end,
     fun(_) -> ?MODULE:stop() end,
     fun() -> {inorder,
               [ ?assertEqual(ok, ?MODULE:add_alert(foo, <<"bar">>)),
                 ?assertEqual([<<"bar">>], ?MODULE:fetch_alerts()),
                 ?assertEqual([], ?MODULE:fetch_alerts())
                ]
              }
     end}.
