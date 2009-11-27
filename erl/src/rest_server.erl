%%% ALK: largely stolen from http://github.com/auser/alice/
%%% original copyright notice follows
%%%-------------------------------------------------------------------
%%% File    : rest_server.erl
%%% Author  : Ari Lerner
%%% Description : 
%%%
%%% Created :  Fri Jun 26 17:14:22 PDT 2009
%%%-------------------------------------------------------------------

-module (rest_server).
-behaviour(gen_server).
%%% -include ("alice.hrl").

-define (INFO (Msg, Args),    io:format("INFO: ~s:~p~n", Msg, Args)).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export ([print_banner/0]).
-record(state, {}).
-define(SERVER, ?MODULE).
-define(JSON_ENCODE(V), mochijson2:encode(V)).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Args) ->
    io:format("start_link~n"),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Args], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
                                                % TODO: Update port args with config variables
init(Args) ->
    io:format("init~n"),
    io:format("before banner~n"),
    print_banner(),
    io:format("before start_mochiweb~n"),
    Res = (catch start_mochiweb(Args)),
    io:format("Started mochiweb with: ~p~nRes:~p~n", [Args], Res),
    {ok, #state{}}.


print_banner() -> io:format("Hi.~n").

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    mochiweb_http:stop(),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
start_mochiweb(Args) ->
    [Port] = Args,
    io:format("Starting mochiweb_http with ~p~n", [Port]),
    mochiweb_http:start([ {port, Port},
                          {loop, fun dispatch_requests/1}]).

dispatch_requests(Req) ->
    Path = Req:get(raw_path),
    Action = clean_path(Path),
    handle_raw(Action, Req).

handle_raw(Path, Req) ->
    case file:read_file(Path) of
        {ok, Contents} -> Req:ok({"text/html", Contents});
        _ -> route(string:tokens(Path, "/"), Req)
    end.

route(["pools"], Req) ->
    handle_pools(Req);
route(["pools", Id], Req) ->
    handle_pool_info(Id, Req);
route(["buckets", Id], Req) ->
    handle_bucket_info(Id, Req);
route(["buckets", Id, "stats"], Req) ->
    handle_bucket_stats(Id, Req);
route(_, Req) ->
    Req:not_found().

reply_json(Req, Body) ->
    Req:ok({"application/json", mochijson2:encode(Body)}).

handle_pools(Req) ->
    reply_json(Req, {struct, [
                              {implementation_version, ""},
                              {pools, [{struct, [{name, "Default Pool"},
                                                 {uri, "/pools/12"},
                                                 {defaultBucketURI, "/buckets/4"}]},
                                       {struct, [{name, "Another Pool"},
                                                 {uri, "/pools/13"},
                                                 {defaultBucketURI, "/buckets/5"}]}]}]}).


handle_pool_info(Id, Req) ->
    Res = case Id of
              "12" -> {struct, [{node, [{struct, [{ip_address, "10.0.1.20"},
                                                  {running, true},
                                                  {ports, [11211]},
                                                  {uri, "https://first_node.in.pool.com:80/pool/Default Pool/node/first_node/"},
                                                  {name, "first_node"},
                                                  {fqdn, "first_node.in.pool.com"}]}, {struct, [{ip_address, "10.0.1.21"},
                                                                                                {running, true},
                                                                                                {ports, [11211]},
                                                                                                {uri, "https://second_node.in.pool.com:80/pool/Default Pool/node/second_node/"},
                                                                                                {name, "second_node"},
                                                                                                {fqdn, "second_node.in.pool.com"}]}]},
                                {bucket, [{struct, [{uri, "/buckets/4"},
                                                    {name, "Excerciser Application"}]}]},
                                {stats, {struct, [{uri, "/buckets/4/stats?really_for_pool=1"}]}},
                                {default_bucket_uri, "/buckets/4"},
                                {name, "Default Pool"}]};
              _ -> {struct, [{node, [{struct, [{ip_address, "10.0.1.22"},
                                               {uptime, 123443},
                                               {running, true},
                                               {ports, [11211]},
                                               {uri, "https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/"},
                                               {name, "first_node"},
                                               {fqdn, "first_node.in.pool.com"}]}, {struct, [{ip_address, "10.0.1.22"},
                                                                                             {uptime, 123123},
                                                                                             {running, true},
                                                                                             {ports, [11211]},
                                                                                             {uri, "https://second_node.in.pool.com:80/pool/Another Pool/node/second_node/"},
                                                                                             {name, "second_node"},
                                                                                             {fqdn, "second_node.in.pool.com"}]}]},
                             {bucket, [{struct, [{uri, "/buckets/5"},
                                                 {name, "Excerciser Another"}]}]},
                             {stats, {struct, [{uri, "/buckets/4/stats?really_for_pool=2"}]}},
                             {default_bucket_uri, "/buckets/5"},
                             {name, "Another Pool"}]}
          end,
    reply_json(Req, Res).

handle_bucket_info(Id, Req) ->
    Res = case Id of
              "4" -> {struct, [{pool_uri, "asdasdasdasd"},
                               {stats, {struct, [{uri, "/buckets/4/stats"}]}},
                               {name, "Excerciser Application"}]};
              _ -> {struct, [{pool_uri, "asdasdasdasd"},
                             {stats, {struct, [{uri, "/buckets/5/stats"}]}},
                             {name, "Excerciser Another"}]}
          end,
    reply_json(Req, Res).

% milliseconds since 1970 Jan 1 at UTC
java_date() ->
    {MegaSec, Sec, Millis} = erlang:now(),
    (MegaSec * 1000000 + Sec) * 1000 + Millis.

handle_bucket_stats(_Id, Req) ->
    Now = java_date(),
    Params = Req:parse_qs(),
    Samples = [{gets, [25, 10, 5, 46, 100, 74]},
               {misses, [100, 74, 25, 10, 5, 46]},
               {sets, [74, 25, 10, 5, 46, 100]},
               {ops, [10, 5, 46, 100, 74, 25]}],
    SamplesSize = 6,
    SamplesInterval = case proplist:get_value(opspersecond_zoom, Params) of
                          "now" -> 1;
                          "1hr" -> 3600/SamplesSize;
                          "24hr" -> 86400/SamplesSize
                      end,
    StartTstampParam = proplist:get_value(opsbysecond_start_tstamp, Params),
    %% cut_number = samples
    %% if params['opsbysecond_start_tstamp']
    %%   start_tstamp = params['opsbysecond_start_tstamp'].to_i/1000.0
    %%   cut_seconds = tstamp - start_tstamp
    %%   if cut_seconds > 0 && cut_seconds < samples_interval*samples
    %%     cut_number = (cut_seconds/samples_interval).floor
    %%   end
    %% end
    CutNumber = case StartTstampParam of
                    undefined -> SamplesSize;
                    _ ->
                        StartTstamp = list_to_float(StartTstampParam),
                        CutMsec = Now - StartTstamp,
                        if
                            ((CutMsec > 0) andalso (CutMsec < SamplesInterval*1000*Samples)) ->
                                trunc(CutMsec/SamplesInterval/1000);
                            true -> SamplesSize
                        end
                end,
    Rotates = (Now div 1000) rem SamplesSize,
    CutSamples = lists:map(fun ({K, S}) ->
                                   %% rv['op'][name] = (rv['op'][name] * 2)[rotates, samples]
                                   %% rv['op'][name] = rv['op'][name][-cut_number..-1]
                                   V = lists:sublist(lists:append(S, S), Rotates + 1, SamplesSize),
                                   NewSamples = lists:sublist(V, SamplesSize-CutNumber+1, CutNumber),
                                   {K, NewSamples}
                           end),
    Res = {struct, [{hot_keys, [{struct, [{name, "user:image:value"},
                                          {gets, 10000},
                                          {bucket, "Excerciser application"},
                                          {misses, 100},
                                          {type, "Persistent"}]},
                                {struct, [{name, "user:image:value2"},
                                          {gets, 10000},
                                          {bucket, "Excerciser application"},
                                          {misses, 100},
                                          {type, "Cache"}]},
                                {struct, [{name, "user:image:value3"},
                                          {gets, 10000},
                                          {bucket, "Excerciser application"},
                                          {misses, 100},
                                          {type, "Persistent"}]},
                                {struct, [{name, "user:image:value4"},
                                          {gets, 10000},
                                          {bucket, "Excerciser application"},
                                          {misses, 100},
                                          {type, "Cache"}]}]},
                    {ops, [{struct, [{tstamp, Now},
                                     {samples_interval, SamplesInterval}
                                     | CutSamples]}]}]},
    reply_json(Req, Res).


% Get the data off the request
decode_data_from_request(Req) ->
    RecvBody = Req:recv_body(),
    Data = case RecvBody of
               undefined -> erlang:list_to_binary("{}");
               <<>> -> erlang:list_to_binary("{}");
               Bin -> Bin
           end,
    {struct, Struct} = mochijson2:decode(Data),
    Struct.

% Get a clean path
% strips off the query string
clean_path(Path) ->
    {CleanPath, _, _} = mochiweb_util:urlsplit_path(Path),
    CleanPath.
%
