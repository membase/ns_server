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

%% Maximum percentage of overhead compared to max bucket size (%)
-define(MAX_OVERHEAD_PERC, 50).

%% Maximum disk usage before warning (%)
-define(MAX_DISK_USED, 90).

-export([start_link/0, stop/0, local_alert/2, global_alert/2, fetch_alerts/0]).


%% Error constants
errors(ip) ->
    "Cannot listen on hostname: ~p";
errors(ep_oom_errors) ->
    "Bucket \"~s\" on node ~s is out of memory";
errors(ep_item_commit_failed) ->
    "Bucket \"~s\" on node ~s failed to write an item";
errors(overhead) ->
    "Metadata on node \"~s\" is over ~p%";
errors(disk) ->
    "Usage of disk \"~s\" on node \"~s\" is over ~p%".

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% @doc Send alert to all connected nodes
-spec global_alert(any(), binary() | string()) -> ok.
global_alert(Type, Msg) ->
    ns_log:log(?MODULE, 1, Msg),
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


handle_call(fetch_alert, _From, #state{history=Hist, queue=Msgs}=State) ->
    Alerts = [Msg || {_Key, Msg, _Time} <- Msgs],
    {reply, Alerts, State#state{history = Hist ++ Msgs, queue = []}};

handle_call({add_alert, Key, Val}, _, #state{queue=Msgs, history=Hist}=State) ->
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
    [oom, ip, write_fail, overhead, disk].

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
            global_alert({ip, node()}, fmt_to_bin(errors(ip), [node()]));
        true ->
            ok
    end,
    Opaque;

%% @doc check how much overhead there is compared to data
check(disk, Opaque, _History) ->
    [case Used > ?MAX_DISK_USED of
         true ->
             {_Sname, Host} = misc:node_name_host(node()),
             Err = fmt_to_bin(errors(disk), [Disk, Host, Used]),
             global_alert({disk, node()}, Err);
         false ->
             ok
     end || {Disk, _Capacity, Used} <- disksup:get_disk_data()],
    Opaque;

%% @doc check how much overhead there is compared to data
check(overhead, Opaque, _History) ->
    [case (fetch_bucket_stat(Bucket, ep_overhead) /
           fetch_bucket_stat(Bucket, ep_max_data_size)) * 100 of
         X when X > ?MAX_OVERHEAD_PERC ->
             {_Sname, Host} = misc:node_name_host(node()),
             Err = fmt_to_bin(errors(overhead), [Host, erlang:round(X)]),
             global_alert({overhead, node()}, Err);
         _  ->
             ok
     end || Bucket <- ns_memcached:active_buckets()],
    Opaque;

%% @doc check for write failures inside ep engine
check(write_fail, Opaque, _History) ->
    check_stat_increased(ep_item_commit_failed, Opaque);

%% @doc check for any oom errors an any bucket
check(oom, Opaque, _History) ->
    check_stat_increased(ep_oom_errors, Opaque).

%% @doc Check if the value of any statistic has increased since
%% last check
check_stat_increased(Stat, Opaque) ->
    New = fetch_buckets_stat(Stat),
    case dict:is_key(Stat, Opaque) of
        false ->
            dict:store(Stat, New, Opaque);
        true ->
            Old = dict:fetch(Stat, Opaque),
            case stat_increased(New, Old) of
                [] ->
                    ok;
                Buckets ->
                    {_Sname, Host} = misc:node_name_host(node()),
                    Key = {stat, node()},
                    [global_alert(Key, fmt_to_bin(errors(Stat), [Bucket, Host]))
                     || Bucket <- Buckets]
            end,
            dict:store(Stat, New, Opaque)
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


%% @doc list of buckets thats measured stats have increased
-spec stat_increased(dict(), dict()) -> list().
stat_increased(New, Old) ->
    [Bucket || {Bucket, Val} <- dict:to_list(New), increased(Bucket, Val, Old)].


%% @doc fetch a list of a stat for all buckets
fetch_buckets_stat(Stat) ->
    dict:from_list(
      [{Bucket, fetch_bucket_stat(Bucket, Stat)}
       || Bucket <- ns_memcached:active_buckets()]
     ).


%% @doc fetch latest value of stat for particular bucket
fetch_bucket_stat(Bucket, Stat) ->
    case stats_archiver:latest(Bucket, minute, Stat) of
        {Stat, X} -> X;
        _ -> 0
    end.


%% @doc Server keeps a list of messages to check against sending
%% the same message repeatedly
-spec expire_history(list()) -> list().
expire_history(Hist) ->
    Now = misc:now_int(),
    [ {Key, Msg, Time} ||
        {Key, Msg, Time} <- Hist, Now - Time < ?ALERT_TIMEOUT ].


%% @doc Lookup old value and test for increase
-spec increased(string(), integer(), dict()) -> true | false.
increased(Key, Val, Dict) ->
    case dict:find(Key, Dict) of
        error ->
            false;
        {ok, Prev} ->
            Val > Prev
    end.


%% Format the error message into a binary
fmt_to_bin(Str, Args) ->
    list_to_binary(lists:flatten(io_lib:format(Str, Args))).


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
