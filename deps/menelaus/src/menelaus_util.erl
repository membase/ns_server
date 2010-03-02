%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_util).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([server_header/0,
         redirect_permanently/2,
         redirect_permanently/3,
         reply_json/2,
         reply_json/3,
         parse_json/1,
         parse_boolean/1,
         expect_config/1,
         expect_prop_value/2,
         get_option/2,
         direct_port/1,
         concat_url_path/1]).

-export([java_date/0,
         string_hash/1,
         my_seed/1]).

-export([stateful_map/3,
         stateful_takewhile/3,
         low_pass_filter/2,
         caching_result/2]).

-import(simple_cache, [call_simple_cache/2]).

%% External API

server_header() ->
    Versions = ns_info:version(),
    ServerHeader = lists:concat([
                       "NorthScale Server ", proplists:get_value(ns_server, Versions)]),
    [{"Pragma", "no-cache"},
     {"Cache-Control", "no-cache no-store max-age=0"},
     {"Server", ServerHeader}].

redirect_permanently(Path, Req) -> redirect_permanently(Path, Req, []).

%% mostly extracted from mochiweb_request:maybe_redirect/3
redirect_permanently(Path, Req, ExtraHeaders) ->
    %% TODO: support https transparently
    Location = "http://" ++ Req:get_header_value("host") ++ Path,
    LocationBin = list_to_binary(Location),
    Top = <<"<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">"
           "<html><head>"
           "<title>301 Moved Permanently</title>"
           "</head><body>"
           "<h1>Moved Permanently</h1>"
           "<p>The document has moved <a href=\"">>,
    Bottom = <<">here</a>.</p></body></html>\n">>,
    Body = <<Top/binary, LocationBin/binary, Bottom/binary>>,
    Req:respond({301,
                 [{"Location", Location},
                  {"Content-Type", "text/html"} | ExtraHeaders],
                 Body}).

reply_json(Req, Body) ->
    Req:ok({"application/json",
            server_header(),
            mochijson2:encode(Body)}).

reply_json(Req, Body, Status) ->
    Req:respond({Status,
                 [{"Content-Type", "application/json"}
                  | server_header()],
                 mochijson2:encode(Body)}).

expect_config(Key) ->
    {value, RV} = ns_config:search(Key),
    RV.

expect_prop_value(K, List) ->
    Ref = make_ref(),
    try
        case proplists:get_value(K, List, Ref) of
            RV when RV =/= Ref -> RV
        end
    catch
        error:X -> erlang:error(X, [K, List])
    end.

direct_port(Node) ->
    case ns_port_server:get_port_server_param(ns_config:get(),
                                              memcached, "-p",
                                              Node) of
        false ->
            ns_log:log(?MODULE, 0003, "missing memcached port"),
            false;
        {value, MemcachedPortStr} ->
            {value, list_to_integer(MemcachedPortStr)}
    end.

%% milliseconds since 1970 Jan 1 at UTC
java_date() ->
    {MegaSec, Sec, Micros} = erlang:now(),
    (MegaSec * 1000000 + Sec) * 1000 + (Micros div 1000).

string_hash(String) ->
    lists:foldl((fun (Val, Acc) -> (Acc * 31 + Val) band 16#0fffffff end),
                0,
                String).

my_seed(Number) ->
    {Number*31, Number*13, Number*113}.

%% applies F to every InList element and current state.
%% F must return pair of {new list element value, new current state}.
%% returns pair of {new list, current state}
full_stateful_map(F, InState, InList) ->
    {RV, State} = full_stateful_map_rec(F, InState, InList, []),
    {lists:reverse(RV), State}.

full_stateful_map_rec(_F, State, [], Acc) ->
    {Acc, State};
full_stateful_map_rec(F, State, [H|Tail], Acc) ->
    {Value, NewState} = F(H, State),
    full_stateful_map_rec(F, NewState, Tail, [Value|Acc]).

%% same as full_stateful_map/3, but discards state and returns only transformed list
stateful_map(F, InState, InList) ->
    element(1, full_stateful_map(F, InState, InList)).

low_pass_filter(Alpha, List) ->
    Beta = 1 - Alpha,
    F = fun (V, Prev) ->
                RV = Alpha*V + Beta*Prev,
                {RV, RV}
        end,
    case List of
        [] -> [];
        [H|Tail] -> [H | stateful_map(F, H, Tail)]
    end.

caching_result(Key, Computation) ->
    case call_simple_cache(lookup, [Key]) of
        [] -> begin
                  V = Computation(),
                  call_simple_cache(insert, [{Key, V}]),
                  V
              end;
        [{_, V}] -> V
    end.

-ifdef(EUNIT).

string_hash_test_() ->
    [
     ?_assert(string_hash("hello1") /= string_hash("hi")),
     ?_assert(string_hash("hi") == ($h*31+$i))
    ].

wrap_tests_with_cache_setup(Tests) ->
    {spawn, {setup,
             fun () ->
                     simple_cache:start_link()
             end,
             fun (_) ->
                     exit(whereis(simple_cache), die)
             end,
             Tests}}.

debugger_apply(Fun, Args) ->
    i:im(),
    {module, _} = i:ii(?MODULE),
    i:iaa([break]),
    ok = i:ib(?MODULE, Fun, length(Args)),
    apply(?MODULE, Fun, Args).

test_under_debugger() ->
    i:im(),
    {module, _} = i:ii(?MODULE),
    i:iaa([init]),
    eunit:test({spawn, {timeout, infinity, {module, ?MODULE}}}, [verbose]).

-endif.

get_option(Option, Options) ->
    {proplists:get_value(Option, Options),
     proplists:delete(Option, Options)}.

stateful_takewhile_rec(_F, [], _State, App) ->
    App;
stateful_takewhile_rec(F, [H|Tail], State, App) ->
    case F(H, State) of
        {true, NewState} ->
            stateful_takewhile_rec(F, Tail, NewState, [H|App]);
        _ -> App
    end.

stateful_takewhile(F, List, State) ->
    lists:reverse(stateful_takewhile_rec(F, List, State, [])).

parse_json(Req) ->
    mochijson2:decode(Req:recv_body()).

parse_boolean(Value) ->
    case Value of
        true -> true;
        false -> false;
        <<"true">> -> true;
        <<"false">> -> false;
        <<"1">> -> true;
        <<"0">> -> false;
        1 -> true;
        0 -> false
    end.

concat_url_path(Segments) ->
    "/" ++ string:join(lists:map(fun mochiweb_util:quote_plus/1, Segments), "/").
