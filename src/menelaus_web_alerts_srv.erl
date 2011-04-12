-module(menelaus_web_alerts_srv).

-behaviour(gen_server).
-define(SERVER, ?MODULE).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% @doc Hold client state for any alerts that need to be shown in
%% the browser, is used by menelaus_web to piggy back for a transport
%% until a long polling transport is used, will be single user
%% until then, many checks for alerts every ?SAMPLE_RATE milliseconds

-record(state, {
          queue = [],
          history = [],
          opaque = dict:new()
         }).

%% Amount of time to wait between state checks (ms)
-define(SAMPLE_RATE, 3000).

%% Amount of time between sending users the same alert (s)
-define(ALERT_TIMEOUT, 60 * 2).

-define(IP_ERR, "Cannot listen on hostname: ~p").
-define(OOM_ERR, "Node ~p is out of Memory").

-export([start_link/0, stop/0, local_alert/2, global_alert/2, fetch_alerts/0]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% @doc Send alert to all connected nodes
global_alert(Type, Msg) ->
    ns_log:log(?MODULE, 1, Msg,[]),
    [rpc:cast(Node, ?MODULE, local_alert, [Type, Msg])
     || Node <- [node() | nodes()]],
    ok.


%% @doc Show to user on running node only
-spec local_alert(atom(), binary()) -> ok | ignored.
local_alert(Key, Val) ->
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
    {ok, #state{}}.


handle_call(fetch_alert, _From, #state{history=Hist, queue=Msgs} = State) ->
    Alerts = [Msg || {_Key, Msg, _Time} <- Msgs],
    {reply, Alerts, State#state{history = Hist ++ Msgs, queue = []}};

handle_call({add_alert, Key, Val}, _, #state{queue=Msgs, history=Hist} = State) ->
    case not alert_exists(Key, Hist, Msgs)  of
        true ->
            {reply, ok, State#state{queue=[{Key, Val, misc:now_int()} | Msgs]}};
        false ->
            {reply, ignored, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.


handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.


handle_info(check_alerts, #state{history=Hist, opaque=Opaque} = State) ->
    {noreply, State#state{
                opaque = check_alerts(Opaque, Hist),
                history = expire_history(Hist)
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


%% @doc Check to see if an alert (by key) is currently in either
%% the message queue or history of recent items sent
alert_exists(Key, History, MsgQueue) ->
    lists:keyfind(Key, 1, History) =/= false
        orelse lists:keyfind(Key, 1, MsgQueue) =/= false.

%% @doc global checks for any server specific problems locally then
%% broadcast alerts to clients connected to any particular node
global_checks() ->
    [oom, ip].

%% @doc fires off various checks
check_alerts(Opaque, Hist) ->
    Fun = fun(X, Dict) -> check(X, Dict, Hist) end,
    lists:foldl(Fun, Opaque, global_checks()).

%% @doc if listening on a non localhost ip, detect differences between
%% external listening host and current node host
-spec check(atom(), dict(), list()) -> dict().
check(ip, Opaque, _History) ->
    {_Name, Host} = misc:node_name_host(node()),
    case can_listen(Host) of
        false ->
            global_alert({ip, node()}, fmt_to_bin(?IP_ERR, [node()]));
        true ->
            ok
    end,
    Opaque;

%% @doc check for any oom errors an any bucket
check(oom, Opaque, _History) ->
    New = sum_oom_errors(),
    case dict:is_key(oom, Opaque) of
        false ->
            dict:store(oom, New, Opaque);
        true ->
            Old = dict:fetch(oom, Opaque),
            case New > Old of
                true ->
                    global_alert({oom, node()}, fmt_to_bin(?OOM_ERR, [node()]));
                false ->
                    ok
            end,
            dict:store(oom, New, Opaque)
    end.


%% @doc check that I can listen on the current host
-spec can_listen(string()) -> boolean().
can_listen(Host) ->
    case inet:getaddr(Host, inet) of
        {error, _Err} ->
            false;
        {ok, IpAddr} ->
            case gen_tcp:listen(0, [inet, {ip, IpAddr}]) of
                {error, _ListErr} ->
                    false;
                {ok, Socket} ->
                    gen_tcp:close(Socket),
                    true
            end
    end.


%% Format the error message into a binary
fmt_to_bin(Str, Args) ->
    list_to_binary(lists:flatten(io_lib:format(Str, Args))).


%% @doc Sum of all oom errors on all buckets
-spec sum_oom_errors() -> integer().
sum_oom_errors() ->
    lists:sum([ bucket_oom_errors(Bucket)
                || Bucket <- ns_memcached:active_buckets() ]).


%% @doc Total count of oom errors on a bucket
-spec bucket_oom_errors(string()) -> integer().
bucket_oom_errors(Bucket) ->
    case stats_archiver:latest(Bucket, minute, ep_oom_errors) of
        {ep_oom_errors, X} -> X;
        _ -> 0
    end.


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

%% Need to split these into seperate tests, but eunit dies on them for now
basic_test_() ->
    {setup,
     fun() -> ?MODULE:start_link() end,
     fun(_) -> ?MODULE:stop() end,
     fun() -> {inorder,
               [
                ?assertEqual(ok, ?MODULE:local_alert(foo, <<"bar">>)),
                ?assertEqual([<<"bar">>], ?MODULE:fetch_alerts()),
                ?assertEqual([], ?MODULE:fetch_alerts()),

                ?assertEqual(ok, ?MODULE:local_alert(bar, <<"bar">>)),
                ?assertEqual(ignored, ?MODULE:local_alert(bar, <<"bar">>)),
                ?assertEqual([<<"bar">>], ?MODULE:fetch_alerts()),
                ?assertEqual([], ?MODULE:fetch_alerts()),

                ?assertEqual(ok, ?MODULE:global_alert(fu, <<"bar">>)),
                ?assertEqual(ok, ?MODULE:global_alert(fu, <<"bar">>)),

                timer:sleep(50),

                ?assertEqual([<<"bar">>], ?MODULE:fetch_alerts()),
                ?assertEqual([], ?MODULE:fetch_alerts())
               ]
              }
     end}.
