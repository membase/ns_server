-module(menelaus_web_alerts_srv).

-include("ns_common.hrl").
-include("ns_stats.hrl").

-include_lib("eunit/include/eunit.hrl").
%% needed to mock ns_config in tests
-include("ns_config.hrl").

-behaviour(gen_server).
-define(SERVER, ?MODULE).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([alert_keys/0]).

%% @doc Hold client state for any alerts that need to be shown in
%% the browser, is used by menelaus_web to piggy back for a transport
%% until a long polling transport is used, will be single user
%% until then, many checks for alerts every ?SAMPLE_RATE milliseconds

-record(state, {
          queue = [],
          history = [],
          opaque = dict:new(),
          checker_pid,
          change_counter = 0
         }).

%% Amount of time to wait between state checks (ms)
-define(SAMPLE_RATE, 3000).

%% Amount of time between sending users the same alert (s)
-define(ALERT_TIMEOUT, 60 * 10).

%% Amount of time to wait between checkout out of disk (s)
-define(DISK_USAGE_TIMEOUT, 60 * 60 * 12).

-export([start_link/0, stop/0, local_alert/2, global_alert/2,
         fetch_alerts/0, consume_alerts/1]).


%% short description for a specific error; used in email subject
short_description(ip) ->
    "IP address changed";
short_description(ep_oom_errors) ->
    "hard out of memory error";
short_description(ep_item_commit_failed) ->
    "write commit failure";
short_description(overhead) ->
    "metadata overhead warning";
short_description(disk) ->
    "approaching full disk warning";
short_description(Other) ->
    %% this case is needed for tests to work
    couch_util:to_list(Other).

%% Error constants
errors(ip) ->
    "IP address seems to have changed. Unable to listen on ~p.";
errors(ep_oom_errors) ->
    "Hard Out Of Memory Error. Bucket \"~s\" on node ~s is full. All memory allocated to this bucket is used for metadata.";
errors(ep_item_commit_failed) ->
    "Write Commit Failure. Disk write failed for item in Bucket \"~s\" on node ~s.";
errors(overhead) ->
    "Metadata overhead warning. Over  ~p% of RAM allocated to bucket  \"~s\" on node \"~s\" is taken up by keys and metadata.";
errors(disk) ->
    "Approaching full disk warning. Usage of disk \"~s\" on node \"~s\" is around ~p%.".

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


%% @doc Send alert to all connected nodes
-spec global_alert(any(), binary() | string()) -> ok.
global_alert(Type, Msg) ->
    ale:info(?USER_LOGGER, to_str(Msg)),
    [rpc:cast(Node, ?MODULE, local_alert, [{Type, node()}, Msg])
     || Node <- [node() | nodes()]],
    ok.


%% @doc Show to user on running node only
-spec local_alert({any(), node()}, binary()) -> ok | ignored.
local_alert(Key, Val) ->
    gen_server:call(?MODULE, {add_alert, Key, Val}).


%% @doc fetch a list of binary string, clearing out the message
%% history
-spec fetch_alerts() -> {list(binary()), binary()}.
fetch_alerts() ->
    diag_handler:diagnosing_timeouts(
      fun () ->
              gen_server:call(?MODULE, fetch_alert)
      end).

-spec consume_alerts(binary()) -> boolean().
consume_alerts(VersionCookie) ->
    gen_server:call(?MODULE, {consume_alerts, VersionCookie}).


stop() ->
    gen_server:cast(?MODULE, stop).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    start_timer(),
    {ok, #state{}}.


handle_call({consume_alerts, PassedCounter}, _From, #state{change_counter = Counter}=State) ->
    NewState = case (catch list_to_integer(binary_to_list(PassedCounter))) of
                   Counter ->
                       %% match
                       State#state{queue=[],
                                   change_counter=Counter+1};
                   _ ->
                       State
               end,
    {reply, NewState =/= State, NewState};

handle_call(fetch_alert, _From, #state{queue=Msgs, change_counter=Counter}=State) ->
    Alerts = [Msg || {_Key, Msg, _Time} <- Msgs],
    {reply, {lists:reverse(Alerts), list_to_binary(integer_to_list(Counter))}, State};

handle_call({add_alert, Key, Val}, _, #state{queue=Msgs, history=Hist, change_counter=Counter}=State) ->
    case lists:keyfind(Key, 1, Hist) of
        false ->
            MsgTuple = {Key, Val, misc:now_int()},
            maybe_send_out_email_alert(Key, Val),
            {reply, ok, State#state{history=[MsgTuple | Hist],
                                    queue=[MsgTuple | lists:keydelete(Key, 1, Msgs)],
                                    change_counter=Counter+1}};
        _ ->
            {reply, ignored, State}
    end.


handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

-spec is_checker_active(undefined | pid()) -> true | false.
is_checker_active(undefined) -> false;
is_checker_active(Pid) ->
    erlang:is_process_alive(Pid).

handle_info(check_alerts, #state{checker_pid = Pid} = State) ->
    case is_checker_active(Pid) of
        true ->
            {noreply, State};
        _ ->
            case misc:flush(check_alerts) of
                0 -> ok;
                N ->
                    ?log_warning("Eaten ~p previously unconsumed check_alerts~n", [N])
            end,
            Self = self(),
            CheckerPid = erlang:spawn_link(fun () ->
                                                   NewOpaque = do_handle_check_alerts_info(State),
                                                   Self ! {merge_opaque_from_checker, NewOpaque}
                                           end),
            {noreply, State#state{checker_pid = CheckerPid}}
    end;

handle_info({merge_opaque_from_checker, NewOpaque},
            #state{history=History} = State) ->
    {noreply, State#state{opaque = NewOpaque,
                          history = expire_history(History),
                          checker_pid = undefined}};

handle_info(_Info, State) ->
    {noreply, State}.

do_handle_check_alerts_info(#state{history=Hist, opaque=Opaque}) ->
    BucketNames = ordsets:intersection(lists:sort(ns_memcached:active_buckets()),
                                       lists:sort(ns_bucket:node_bucket_names(node()))),
    RawPairs = [{Name, stats_reader:latest(minute, node(), Name, 1)} || Name <- BucketNames],
    Stats = [{Name, OrdDict}
             || {Name, {ok, [#stat_entry{values = OrdDict}|_]}} <- RawPairs],
    check_alerts(Opaque, Hist, Stats).

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%% @doc Remind myself to check the alert status
start_timer() ->
    timer2:send_interval(?SAMPLE_RATE, check_alerts).


%% @doc global checks for any server specific problems locally then
%% broadcast alerts to clients connected to any particular node
global_checks() ->
    [oom, ip, write_fail, overhead, disk].

%% @doc fires off various checks
check_alerts(Opaque, Hist, Stats) ->
    Fun = fun(X, Dict) -> check(X, Dict, Hist, Stats) end,
    lists:foldl(Fun, Opaque, global_checks()).


%% @doc if listening on a non localhost ip, detect differences between
%% external listening host and current node host
-spec check(atom(), dict(), list(), [{atom(),number()}]) -> dict().
check(ip, Opaque, _History, _Stats) ->
    {_Name, Host} = misc:node_name_host(node()),
    case can_listen(Host) of
        false ->
            global_alert(ip, fmt_to_bin(errors(ip), [node()]));
        true ->
            ok
    end,
    Opaque;

%% @doc check the capacity of the drives used for db and log files
check(disk, Opaque, _History, _Stats) ->

    Mounts = ns_disksup:get_disk_data(),

    UsedPre = [ns_storage_conf:this_node_dbdir(),
               ns_storage_conf:this_node_ixdir(),
               ns_storage_conf:this_node_logdir()],
    UsedFiles = [X || {ok, X} <- UsedPre],

    UsedMountsTmp =
        [begin {ok, RealFile} = misc:realpath(File, "/"),
               {ok, Mnt} = ns_storage_conf:extract_disk_stats_for_path(Mounts, RealFile),
               Mnt
         end || File <- UsedFiles],
    UsedMounts = sets:to_list(sets:from_list(UsedMountsTmp)),
    {value, Config} = ns_config:search(alert_limits),
    MaxDiskUsed = proplists:get_value(max_disk_used, Config),
    OverDisks = [ {Disk, Used}
                  || {Disk, _Cap, Used} <- UsedMounts, Used > MaxDiskUsed],

    Fun = fun({Disk, Used}, Acc) ->
                  Key = list_to_atom("disk_check_" ++ Disk),
                  case hit_rate_limit(Key, Acc) of
                      false ->
                          {_Sname, Host} = misc:node_name_host(node()),
                          Err = fmt_to_bin(errors(disk), [Disk, Host, Used]),
                          global_alert(disk, Err),
                          dict:store(Key, misc:now_int(), Acc);
                      true ->
                          Acc
                  end
          end,

    lists:foldl(Fun, Opaque, OverDisks);

%% @doc check how much overhead there is compared to data
check(overhead, Opaque, _History, Stats) ->
    [case over_threshold(fetch_bucket_stat(Stats, Bucket, ep_meta_data_memory),
                         fetch_bucket_stat(Stats, Bucket, ep_max_size)) of
         {true, X} ->
             {_Sname, Host} = misc:node_name_host(node()),
             Err = fmt_to_bin(errors(overhead), [erlang:trunc(X), Bucket, Host]),
             global_alert({overhead, Bucket}, Err);
         false  ->
             ok
     end || Bucket <- ns_memcached:active_buckets()],
    Opaque;

%% @doc check for write failures inside ep engine
check(write_fail, Opaque, _History, Stats) ->
    check_stat_increased(Stats, ep_item_commit_failed, Opaque);

%% @doc check for any oom errors an any bucket
check(oom, Opaque, _History, Stats) ->
    check_stat_increased(Stats, ep_oom_errors, Opaque).


%% @doc only check for disk usage if there has been no previous
%% errors or last error was over the timeout ago
-spec hit_rate_limit(atom(), dict()) -> true | false.
hit_rate_limit(Key, Dict) ->
    case dict:find(Key, Dict) of
        error ->
            false;
        {ok, Value} ->
            Value + ?DISK_USAGE_TIMEOUT > misc:now_int()
    end.


%% @doc calculate percentage of overhead and if it is over threshold
-spec over_threshold(integer(), integer()) -> false | {true, float()}.
over_threshold(_Ep, 0) ->
    false;
over_threshold(EpErrs, Max) ->
    {value, Config} = ns_config:search(alert_limits),
    MaxOverheadPerc = proplists:get_value(max_overhead_perc, Config),
    Perc = (EpErrs / Max) * 100,
    case Perc > MaxOverheadPerc of
        true -> {true, Perc};
        false  -> false
    end.


%% @doc Check if the value of any statistic has increased since
%% last check
check_stat_increased(Stats, StatName, Opaque) ->
    New = fetch_buckets_stat(Stats, StatName),
    case dict:is_key(StatName, Opaque) of
        false ->
            dict:store(StatName, New, Opaque);
        true ->
            Old = dict:fetch(StatName, Opaque),
            case stat_increased(New, Old) of
                [] ->
                    ok;
                Buckets ->
                    {_Sname, Host} = misc:node_name_host(node()),
                    [global_alert({StatName, Bucket}, fmt_to_bin(errors(StatName), [Bucket, Host]))
                     || Bucket <- Buckets]
            end,
            dict:store(StatName, New, Opaque)
    end.


%% @doc check that I can listen on the current host
-spec can_listen(string()) -> boolean().
can_listen(Host) ->
    case inet:getaddr(Host, inet) of
        {error, Err} ->
            ?log_error("Cannot listen due to ~p from inet:getaddr~n", [Err]),
            false;
        {ok, IpAddr} ->
            case gen_udp:open(0, [inet, {ip, IpAddr}]) of
                {error, ListErr} ->
                    ?log_error("gen_udp:open failed due to ~p", [ListErr]),
                    false;
                {ok, Socket} ->
                    gen_udp:close(Socket),
                    true
            end
    end.


%% @doc list of buckets thats measured stats have increased
-spec stat_increased(dict(), dict()) -> list().
stat_increased(New, Old) ->
    [Bucket || {Bucket, Val} <- dict:to_list(New), increased(Bucket, Val, Old)].


%% @doc fetch a list of a stat for all buckets
fetch_buckets_stat(Stats, StatName) ->
    dict:from_list(
      [{Bucket, fetch_bucket_stat(Stats, Bucket, StatName)}
       || {Bucket, _OrdDict} <- Stats]
     ).


%% @doc fetch latest value of stat for particular bucket
fetch_bucket_stat(Stats, Bucket, StatName) ->
    OrdDict = case orddict:find(Bucket, Stats) of
                  {ok, KV} ->
                      KV;
                  _ ->
                      []
              end,
    case orddict:find(StatName, OrdDict) of
        {ok, V} -> V;
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


-spec to_str(binary() | string()) -> string().
to_str(Msg) when is_binary(Msg) ->
    binary_to_list(Msg);
to_str(Msg) ->
    Msg.

extract_alert_key({Key, _Bucket}) ->
    Key;
extract_alert_key(Key) ->
    Key.

maybe_send_out_email_alert({Key0, Node}, Message) ->
    case Node =:= node() of
        true ->
            Key = extract_alert_key(Key0),

            {value, Config} = ns_config:search(email_alerts),
            case proplists:get_bool(enabled, Config) of
                true ->
                    Description = short_description(Key),
                    ns_mail:send_alert_async(Key, Description, Message, Config);
                false ->
                    ok
            end;
        false ->
            ok
    end.

alert_keys() ->
    [ip, disk, overhead, ep_oom_errors, ep_item_commit_failed].

%% Cant currently test the alert timeouts as would need to mock
%% calls to the archiver

run_basic_test_do() ->
    ?assertEqual(ok, ?MODULE:local_alert({foo, node()}, <<"bar">>)),
    ?assertMatch({[<<"bar">>], _}, ?MODULE:fetch_alerts()),
    {[<<"bar">>], Opaque1} = ?MODULE:fetch_alerts(),
    ?assertMatch({true, {[], _}}, {?MODULE:consume_alerts(Opaque1), ?MODULE:fetch_alerts()}),

    ?assertEqual(ok, ?MODULE:local_alert({bar, node()}, <<"bar">>)),
    ?assertEqual(ignored, ?MODULE:local_alert({bar, node()}, <<"bar">>)),
    {[<<"bar">>], Opaque2} = ?MODULE:fetch_alerts(),
    true = (Opaque1 =/= Opaque2),
    ?assertEqual(false, ?MODULE:consume_alerts(Opaque1)),
    ?assertEqual(true, ?MODULE:consume_alerts(Opaque2)),
    ?assertMatch({[], _}, ?MODULE:fetch_alerts()),

    ?assertEqual(ok, ?MODULE:global_alert(fu, <<"bar">>)),
    ?assertEqual(ok, ?MODULE:global_alert(fu, <<"bar">>)),
    ?assertMatch({[<<"bar">>], _}, ?MODULE:fetch_alerts()).

basic_test() ->
    {ok, Pid} = ?MODULE:start_link(),

    %% return empty alerts configuration so that no attempts to send anything
    %% are performed
    ns_config:test_setup([{email_alerts, []}]),

    try
        run_basic_test_do()
    after
        erlang:unlink(Pid),
        exit(Pid, shutdown),
        misc:wait_for_process(Pid, infinity)
    end.
