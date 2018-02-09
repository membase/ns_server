%% @author Couchbase <info@couchbase.com>
%% @copyright 2009-2018 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @doc Web server for menelaus.

-module(menelaus_util).
-author('Northscale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-include("ns_common.hrl").
-include("menelaus_web.hrl").
-include("pipes.hrl").

-export([redirect_permanently/2,
         reply/2,
         reply/3,
         reply/4,
         reply_ok/3,
         reply_ok/4,
         reply_text/3,
         reply_text/4,
         reply_json/2,
         reply_json/3,
         reply_json/4,
         parse_json/1,
         reply_not_found/1,
         serve_file/3,
         serve_file/4,
         serve_static_file/4,
         parse_boolean/1,
         get_option/2,
         local_addr/1,
         remote_addr_and_port/1,
         concat_url_path/1,
         concat_url_path/2,
         bin_concat_path/1,
         bin_concat_path/2,
         parse_validate_boolean_field/3,
         parse_validate_number/3,
         parse_validate_number/4,
         parse_validate_port_number/1,
         validate_email_address/1,
         insecure_pipe_through_command/2,
         encode_json/1,
         is_valid_positive_integer/1,
         is_valid_positive_integer_in_range/3,
         validate_boolean/2,
         validate_dir/2,
         validate_integer/2,
         validate_range/4,
         validate_range/5,
         validate_unsupported_params/1,
         validate_has_params/1,
         validate_any_value/2,
         validate_any_value/3,
         validate_by_fun/3,
         validate_one_of/3,
         validate_one_of/4,
         validate_required/2,
         validate_prohibited/2,
         validate_json_object/2,
         execute_if_validated/3,
         execute_if_validated/4,
         get_values/1,
         return_value/3,
         return_error/3,
         format_server_time/1,
         format_server_time/2,
         ensure_local/1,
         reply_global_error/2,
         reply_error/3,
         require_auth/1,
         send_chunked/3,
         handle_streaming/2,
         assert_is_enterprise/0,
         assert_is_45/0,
         assert_is_50/0,
         assert_is_vulcan/0]).

%% used by parse_validate_number
-export([list_to_integer/1, list_to_float/1]).

%% for hibernate
-export([handle_streaming_wakeup/4]).

%% External API

-define(CACHE_CONTROL, "Cache-Control").  %% TODO: Move to an HTTP header file.
%% TODO: Validate adding {"Content-Security-Policy", "script-src 'self'"} to
%% BASE_HEADERS does not break anything.
-define(BASE_HEADERS, [{"Server", "Couchbase Server"}]).
-define(SEC_HEADERS,  [{"X-Content-Type-Options", "nosniff"},
                       {"X-Frame-Options", "DENY"},
                       {"X-Permitted-Cross-Domain-Policies", "none"},
                       {"X-XSS-Protection", "1; mode=block"}]).
-define(NO_CACHE_HEADERS, [{?CACHE_CONTROL, "no-cache,no-store,must-revalidate"},
                           {"Expires", "Thu, 01 Jan 1970 00:00:00 GMT"},
                           {"Pragma", "no-cache"}]).

maybe_get_sec_hdrs(SCfg, Body) ->
     case lists:keysearch(enabled, 1, SCfg) of
         {value, {enabled, false}} ->
             [];
         _ ->
             Body()
     end.

%% Here we get the values for secure headers from the ns_config.
%% Default values are as below:
%% {"X-Content-Type-Options", "nosniff"},
%% {"X-Frame-Options", "DENY"},
%% {"X-Permitted-Cross-Domain-Policies", "none"},
%% {"X-XSS-Protection", "1; mode=block"}]).
%%
%% These can be overridden by the user.
compute_sec_headers() ->
     {value, SCfg} = ns_config:search(ns_config:latest(), secure_headers),
     maybe_get_sec_hdrs(SCfg,
          fun() ->
                  lists:foldl(
                    fun({Hdr, DefVal}, Acc) ->
                            case lists:keysearch(Hdr, 1, SCfg) of
                                false ->
                                    [{Hdr, DefVal} | Acc];
                                {value, {Hdr, disable}} ->
                                    Acc;
                                {value, {Hdr, X}} ->
                                    [{Hdr, X} | Acc]
                            end
                    end, [], ?SEC_HEADERS)
          end).

%% response_header takes a proplist of headers or pseudo-header
%% descripts and augments it with response specific headers.
%% Since any given header can only be specified once, headers at the front
%% of the proplist have priority over the same header later in the
%% proplist.
%% The following pseudo-headers are supported:
%%   {allow_cache, true}  -- Enables long duration caching
%%   {allow_cache, false} -- Disables cache via multiple headers
%% If neither allow_cache or the "Cache-Control" header are specified
%% {allow_cache, false} is applied.
-spec response_headers([{string(),string()}|{atom(), atom()}]) -> [{string(), string()}].
response_headers(Headers) ->
    {Expanded, _} =
        lists:foldl(
          fun({allow_cache, _}, {Acc, _CacheControl = true}) ->
                  {Acc, true};
             ({allow_cache, _Value = true}, {Acc, _}) ->
                  {[{?CACHE_CONTROL, "max-age=30000000"} | Acc], true};
             ({allow_cache, _Value = false}, {Acc, _}) ->
                  {?NO_CACHE_HEADERS ++ Acc, true};
             ({Header = ?CACHE_CONTROL, Value}, {Acc, _}) ->
                  {[{Header, Value} | Acc], true};
             ({Header, Value}, {Acc, CacheControl}) when is_list(Header) ->
                  {[{Header, Value} | Acc], CacheControl}
          end, {[], false},
          Headers ++ [{allow_cache, false} | ?BASE_HEADERS] ++ compute_sec_headers()),
    lists:ukeysort(1, lists:reverse(Expanded)).

%% mostly extracted from mochiweb_request:maybe_redirect/3
redirect_permanently(Path, Req) ->
    Scheme = case Req:get(socket) of
                 {ssl, _} ->
                     "https://";
                 _ ->
                     "http://"
             end,
    Location =
        case Req:get_header_value("host") of
            undefined -> Path;
            X -> Scheme ++ X ++ Path
        end,
    LocationBin = list_to_binary(Location),
    Top = <<"<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">"
           "<html><head>"
           "<title>301 Moved Permanently</title>"
           "</head><body>"
           "<h1>Moved Permanently</h1>"
           "<p>The document has moved <a href=\"">>,
    Bottom = <<">here</a>.</p></body></html>\n">>,
    Body = <<Top/binary, LocationBin/binary, Bottom/binary>>,
    reply(Req, Body, 301, [{"Location", Location}, {"Content-Type", "text/html"}]).

reply_not_found(Req) ->
    reply_not_found(Req, []).

reply_not_found(Req, ExtraHeaders) ->
    reply_text(Req, "Requested resource not found.\r\n", 404, ExtraHeaders).

reply_text(Req, Message, Code) ->
    reply_text(Req, Message, Code, []).

reply_text(Req, Message, Code, ExtraHeaders) ->
    reply(Req, Message, Code, [{"Content-Type", "text/plain"} | ExtraHeaders]).

reply_json(Req, Body) ->
    reply_ok(Req, "application/json", encode_json(Body)).

reply_json(Req, Body, Code) ->
    reply(Req, encode_json(Body), Code, [{"Content-Type", "application/json"}]).

reply_json(Req, Body, Code, ExtraHeaders) ->
    reply(Req, encode_json(Body), Code, [{"Content-Type", "application/json"} | ExtraHeaders]).

log_web_hit(Peer, Req, Resp) ->
    Level = case menelaus_auth:extract_auth(Req) of
                {[$@ | _], _} ->
                    debug;
                 _ ->
                    info
            end,
    ale:xlog(?ACCESS_LOGGER, Level, {Peer, Req, Resp}, "", []).

reply_ok(Req, ContentType, Body) ->
    reply_ok(Req, ContentType, Body, []).

reply_ok(Req, ContentType, Body, ExtraHeaders) ->
    Peer = Req:get(peer),
    Resp = Req:ok({ContentType, response_headers(ExtraHeaders), Body}),
    log_web_hit(Peer, Req, Resp),
    Resp.

reply(Req, Code) ->
    reply(Req, [], Code, []).

reply(Req, Code, ExtraHeaders) ->
    reply(Req, [], Code, ExtraHeaders).

reply(Req, Body, Code, ExtraHeaders) ->
    respond(Req, {Code, response_headers(ExtraHeaders), Body}).

respond(Req, RespTuple) ->
    Peer = Req:get(peer),
    Resp = Req:respond(RespTuple),
    log_web_hit(Peer, Req, Resp),
    Resp.

-include_lib("kernel/include/file.hrl").

%% Originally from mochiweb_request.erl maybe_serve_file/2
%% and modified to handle user-defined content-type
serve_static_file(Req, {DocRoot, Path}, ContentType, ExtraHeaders) ->
    serve_static_file(Req, filename:join(DocRoot, Path), ContentType, ExtraHeaders);
serve_static_file(Req, File, ContentType, ExtraHeaders) ->
    case file:read_file_info(File) of
        {ok, FileInfo} ->
            LastModified = httpd_util:rfc1123_date(FileInfo#file_info.mtime),
            case Req:get_header_value("if-modified-since") of
                LastModified ->
                    reply(Req, 304, ExtraHeaders);
                _ ->
                    case file:open(File, [raw, binary]) of
                        {ok, IoDevice} ->
                            Res = reply_ok(Req, ContentType,
                                           {file, IoDevice},
                                           [{"last-modified", LastModified}
                                            | ExtraHeaders]),
                            file:close(IoDevice),
                            Res;
                        _ ->
                            reply_not_found(Req, ExtraHeaders)
                    end
            end;
        {error, _} ->
            reply_not_found(Req, ExtraHeaders)
    end.

serve_file(Req, File, Root) ->
    serve_file(Req, File, Root, []).

serve_file(Req, File, Root, ExtraHeaders) ->
    Peer = Req:get(peer),
    Resp = Req:serve_file(File, Root, response_headers(ExtraHeaders ++ [{allow_cache, true}])),
    log_web_hit(Peer, Req, Resp),
    Resp.

get_option(Option, Options) ->
    {proplists:get_value(Option, Options),
     proplists:delete(Option, Options)}.

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

url_path_iolist(Path, Props) when is_binary(Path) ->
    do_url_path_iolist(Path, Props);
url_path_iolist(Segments, Props) ->
    Path = [[$/, mochiweb_util:quote_plus(S)] || S <- Segments],
    do_url_path_iolist(Path, Props).

do_url_path_iolist(Path, Props) ->
    case Props of
        [] ->
            Path;
        _ ->
            QS = mochiweb_util:urlencode(Props),
            [Path, $?, QS]
    end.

concat_url_path(Segments) ->
    concat_url_path(Segments, []).
concat_url_path(Segments, Props) ->
    lists:flatten(url_path_iolist(Segments, Props)).

bin_concat_path(Segments) ->
    bin_concat_path(Segments, []).
bin_concat_path(Segments, Props) ->
    iolist_to_binary(url_path_iolist(Segments, Props)).

parse_validate_boolean_field(JSONName, CfgName, Params) ->
    case proplists:get_value(JSONName, Params) of
        undefined -> [];
        "true" -> [{ok, CfgName, true}];
        "false" -> [{ok, CfgName, false}];
        _ -> [{error, JSONName, iolist_to_binary(io_lib:format("~s is invalid", [JSONName]))}]
    end.

-spec parse_validate_number(string(), (integer() | undefined), (integer() | undefined)) ->
                                   invalid | too_small | too_large | {ok, integer()}.
parse_validate_number(String, Min, Max) ->
    parse_validate_number(String, Min, Max, list_to_integer).

list_to_integer(A) -> erlang:list_to_integer(A).

list_to_float(A) -> try erlang:list_to_integer(A)
                    catch _:_ ->
                            erlang:list_to_float(A)
                    end.

-spec parse_validate_number(string(), (number() | undefined), (number() | undefined),
                            list_to_integer | list_to_float) ->
                                   invalid | too_small | too_large | {ok, integer()}.
parse_validate_number(String, Min, Max, Fun) ->
    Parsed = (catch menelaus_util:Fun(string:strip(String))),
    if
        is_number(Parsed) ->
            if
                Min =/= undefined andalso Parsed < Min -> too_small;
                Max =/= undefined andalso Max =/= infinity andalso
                  Parsed > Max -> too_large;
                true -> {ok, Parsed}
            end;
       true -> invalid
    end.

parse_validate_port_number(StringPort) ->
    case parse_validate_number(StringPort, 1024, 65535) of
        {ok, Port} ->
            Port;
        invalid ->
            throw({error, [<<"Port must be a number.">>]});
        _ ->
            throw({error, [<<"The port number must be greater than 1023 and less than 65536.">>]})
    end.

%% does a simple email address validation
validate_email_address(Address) ->
    {ok, RE} = re:compile("^[^@]+@.+$", [multiline]), %%" "hm, even erlang-mode is buggy :("),
    RV = re:run(Address, RE),
    case RV of
        {match, _} -> true;
        _ -> false
    end.

%% Extract the local address of the socket used for the request
local_addr(Req) ->
    Socket = Req:get(socket),
    Address = case Socket of
                  {ssl, SSLSock} ->
                      {ok, {AV, _Port}} = ssl:sockname(SSLSock),
                      AV;
                  _ ->
                      {ok, {AV, _Port}} = inet:sockname(Socket),
                      AV
              end,
    misc:maybe_add_brackets(inet:ntoa(Address)).

remote_addr_and_port(Req) ->
    case inet:peername(Req:get(socket)) of
        {ok, {Address, Port}} ->
            misc:maybe_add_brackets(inet:ntoa(Address)) ++ ":" ++ integer_to_list(Port);
        Error ->
            ?log_error("remote_addr failed: ~p", Error),
            "unknown"
    end.

pipe_through_command_rec(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            pipe_through_command_rec(Port, [Data | Acc]);
        {Port, {exit_status, _}} ->
            lists:reverse(Acc);
        X when is_tuple(X) andalso element(1, X) =:= Port ->
            io:format("ignoring port message: ~p~n", [X]),
            pipe_through_command_rec(Port, Acc)
    end.

%% this is NOT secure, because I cannot make erlang ports work as
%% popen. We're missing ability to close write side of the port.
insecure_pipe_through_command(Command, IOList) ->
    TmpFile = filename:join(path_config:component_path(tmp),
                            "pipethrough." ++ integer_to_list(erlang:phash2([self(), os:getpid(), timestamp]))),
    filelib:ensure_dir(TmpFile),
    misc:write_file(TmpFile, IOList),
    Port = open_port({spawn, Command ++ " <" ++ mochiweb_util:shell_quote(TmpFile)}, [binary, in, exit_status]),
    RV = pipe_through_command_rec(Port, []),
    file:delete(TmpFile),
    RV.

strip_json_struct({struct, Pairs}) -> {strip_json_struct(Pairs)};
strip_json_struct(List) when is_list(List) -> [strip_json_struct(E) || E <- List];
strip_json_struct({Key, Value}) -> {Key, strip_json_struct(Value)};
strip_json_struct(Other) -> Other.

encode_json(JSON) ->
    Stripped = try strip_json_struct(JSON)
               catch T1:E1 ->
                       ?log_debug("errored while stripping:~n~p", [JSON]),
                       Stack1 = erlang:get_stacktrace(),
                       erlang:raise(T1, E1, Stack1)
               end,

    try
        ejson:encode(Stripped)
    catch T:E ->
            ?log_debug("errored while sending:~n~p~n->~n~p", [JSON, Stripped]),
            Stack = erlang:get_stacktrace(),
            erlang:raise(T, E, Stack)
    end.

is_valid_positive_integer(String) ->
    Int = (catch erlang:list_to_integer(String)),
    (is_integer(Int) andalso (Int > 0)).

is_valid_positive_integer_in_range(String, Min, Max) ->
    Int = (catch erlang:list_to_integer(String)),
    (is_integer(Int) andalso (Int >= Min) andalso (Int =< Max)).

return_value(Name, Value, {OutList, InList, Errors}) ->
    {lists:keydelete(atom_to_list(Name), 1, OutList),
     lists:keystore(Name, 1, InList, {Name, Value}), Errors}.

return_error(Name, Error, {OutList, InList, Errors}) ->
    {lists:keydelete(atom_to_list(Name), 1, OutList), InList,
     [{Name, iolist_to_binary(Error)} | Errors]}.

validate_by_fun(Fun, Name, {_, InList, _} = State) ->
    Value = proplists:get_value(Name, InList),
    case Value of
        undefined ->
            State;
        _ ->
            case Fun(Value) of
                ok ->
                    State;
                {value, V} ->
                    return_value(Name, V, State);
                {error, Error} ->
                    return_error(Name, Error, State)
            end
    end.

simple_term_to_list(X) when is_atom(X) ->
    atom_to_list(X);
simple_term_to_list(X) when is_integer(X) ->
    integer_to_list(X);
simple_term_to_list(X) ->
    X.

validate_one_of(Name, List, State) ->
    validate_one_of(Name, List, State, fun list_to_atom/1).

validate_one_of(Name, List, {OutList, _, _} = State, Convert) ->
    StringList = [simple_term_to_list(X) || X <- List],
    Value = proplists:get_value(atom_to_list(Name), OutList),
    case Value of
        undefined ->
            State;
        _ ->
            StringValue = simple_term_to_list(Value),
            case lists:member(StringValue, StringList) of
                true ->
                    return_value(Name, Convert(StringValue), State);
                false ->
                    return_error(
                      Name,
                      io_lib:format(
                        "The value must be one of the following: [~s]",
                        [string:join(StringList, ",")]), State)
            end
    end.

validate_boolean(Name, State) ->
    validate_one_of(Name, [true, false], State).

validate_dir(Name, {_, InList, _} = State) ->
    Value = proplists:get_value(Name, InList),
    case Value of
        undefined ->
            State;
        _ ->
            case filelib:is_dir(Value) of
                true ->
                    return_value(Name, Value, State);
                false ->
                    return_error(Name, "The value must be a valid directory", State)
            end
    end.

validate_integer(Name, {OutList, _, _} = State) ->
    Value = proplists:get_value(atom_to_list(Name), OutList),
    case Value of
        undefined ->
            State;
        _ ->
            Int = (catch erlang:list_to_integer(Value)),
            case is_integer(Int) of
                true ->
                    return_value(Name, Int, State);
                false ->
                    return_error(Name, "The value must be an integer", State)
            end
    end.

validate_range(Name, Min, Max, State) ->
    ErrorFun = fun (_NameArg, MinArg, MaxArg) ->
                       io_lib:format("The value must be in range from ~p to ~p",
                                     [MinArg, MaxArg])
               end,
    validate_range(Name, Min, Max, ErrorFun, State).

validate_range(Name, Min, Max, ErrorFun, State) ->
    validate_by_fun(fun (Value) ->
                            case (Value >= Min) andalso (Value =< Max) of
                                true ->
                                    ok;
                                false ->
                                    {error, ErrorFun(Name, Min, Max)}
                            end
                    end, Name, State).

validate_unsupported_params({OutList, InList, Errors}) ->
    NewErrors = [{list_to_binary(Key),
                  iolist_to_binary(["Found unsupported key ", Key])} || {Key, _} <- OutList] ++ Errors,
    {OutList, InList, NewErrors}.

validate_has_params({[], InList, Errors}) ->
    {[], InList, [{<<"_">>, <<"Request should have form parameters">>} | Errors]};
validate_has_params(State) ->
    State.

validate_any_value(Name, State) ->
    validate_any_value(Name, State, fun (X) -> X end).

validate_any_value(Name, {OutList, _, _} = State, Convert) ->
    case lists:keyfind(atom_to_list(Name), 1, OutList) of
        false ->
            State;
        {_, Value} ->
            return_value(Name, Convert(Value), State)
    end.

validate_required(Name, {OutList, _, _} = State) ->
    case lists:keyfind(atom_to_list(Name), 1, OutList) of
        false ->
            return_error(Name, "The value must be supplied", State);
        _ ->
            State
    end.

validate_prohibited(Name, {OutList, _, _} = State) ->
    case lists:keyfind(atom_to_list(Name), 1, OutList) of
        false ->
            State;
        _ ->
            return_error(Name, "The value must not be supplied", State)
    end.

execute_if_validated(Fun, Req, {_, Values, Errors}) ->
    ValidateOnly = proplists:get_value("just_validate", Req:parse_qs()) =:= "1",
    case {ValidateOnly, Errors} of
        {true, _} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 200);
        {false, []} ->
            Fun(Values);
        {false, _} ->
            reply_json(Req, {struct, [{errors, {struct, Errors}}]}, 400)
    end.

execute_if_validated(Fun, Req, Args, Validators) ->
    execute_if_validated(Fun, Req,
                         functools:chain({Args, [], []}, Validators)).

validate_json_object(Body, Validators) ->
    try ejson:decode(Body) of
        {KVList} ->
            Params = lists:map(fun ({Name, Value}) ->
                                       {binary_to_list(Name), Value}
                               end, KVList),
            functools:chain({Params, [], []}, Validators);
        _ ->
            {[], [], [{<<"Data">>, <<"Unexpected Json">>}]}
    catch _:_ ->
            {[], [], [{<<"Data">>, <<"Invalid Json">>}]}
    end.

get_values({_, Values, _}) ->
    Values.

format_server_time(DateTime) ->
    format_server_time(DateTime, 0).

format_server_time({{YYYY, MM, DD}, {Hour, Min, Sec}}, MicroSecs) ->
    list_to_binary(
      io_lib:format("~4.4.0w-~2.2.0w-~2.2.0wT~2.2.0w:~2.2.0w:~2.2.0w.~3.3.0wZ",
                    [YYYY, MM, DD, Hour, Min, Sec, MicroSecs div 1000])).

ensure_local(Req) ->
    case Req:get(peer) of
        "127.0.0.1" ->
            ok;
        "::1" ->
            ok;
        _ ->
            erlang:throw({web_exception, 400, <<"API is accessible from localhost only">>, []})
    end.

reply_global_error(Req, Error) ->
    reply_error(Req, "_", Error).

reply_error(Req, Field, Error) ->
    reply_json(
      Req, {struct, [{errors, {struct, [{iolist_to_binary([Field]), iolist_to_binary([Error])}]}}]}, 400).

require_auth(Req) ->
    case Req:get_header_value("invalid-auth-response") of
        "on" ->
            %% We need this for browsers that display auth
            %% dialog when faced with 401 with
            %% WWW-Authenticate header response, even via XHR
            reply(Req, 401);
        _ ->
            reply(Req, 401, [{"WWW-Authenticate",
                              "Basic realm=\"Couchbase Server Admin / REST\""}])
    end.

send_chunked(Req, StatusCode, ExtraHeaders) ->
    ?make_consumer(
       begin
           Resp = respond(
                    Req, {StatusCode, response_headers(ExtraHeaders), chunked}),
           pipes:foreach(?producer(),
                         fun (Part) ->
                                 Resp:write_chunk(Part)
                         end),
           Resp:write_chunk(<<>>)
       end).

handle_streaming(F, Req) ->
    HTTPRes = reply_ok(Req, "application/json; charset=utf-8", chunked),
    %% Register to get config state change messages.
    menelaus_event:register_watcher(self()),
    Sock = Req:get(socket),
    mochiweb_socket:setopts(Sock, [{active, true}]),
    handle_streaming(F, Req, HTTPRes, undefined).

streaming_inner(F, HTTPRes, LastRes) ->
    Res = F(normal, stable),
    case Res =:= LastRes of
        true ->
            ok;
        false ->
            ResNormal = case Res of
                            {just_write, Stuff} ->
                                Stuff;
                            _ ->
                                F(normal, unstable)
                        end,
            Encoded = case ResNormal of
                          {write, Bin} -> Bin;
                          _ -> encode_json(ResNormal)
                      end,
            HTTPRes:write_chunk(Encoded),
            HTTPRes:write_chunk("\n\n\n\n")
    end,
    Res.

handle_streaming(F, Req, HTTPRes, LastRes) ->
    Res =
        try streaming_inner(F, HTTPRes, LastRes)
        catch exit:normal ->
                HTTPRes:write_chunk(""),
                exit(normal)
        end,
    request_throttler:hibernate(?MODULE, handle_streaming_wakeup, [F, Req, HTTPRes, Res]).

handle_streaming_wakeup(F, Req, HTTPRes, Res) ->
    receive
        notify_watcher ->
            timer:sleep(50),
            misc:flush(notify_watcher),
            ok;
        _ ->
            exit(normal)
    after 25000 ->
            ok
    end,
    handle_streaming(F, Req, HTTPRes, Res).

assert_is_enterprise() ->
    case cluster_compat_mode:is_enterprise() of
        true ->
            ok;
        _ ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint requires enterprise edition",
                          [{"X-enterprise-edition-needed", 1}]})
    end.

assert_is_45() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_45/0).

assert_is_50() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_50/0).

assert_is_vulcan() ->
    assert_cluster_version(fun cluster_compat_mode:is_cluster_vulcan/0).

assert_cluster_version(Fun) ->
    case Fun() of
        true ->
            ok;
        false ->
            erlang:throw({web_exception,
                          400,
                          "This http API endpoint isn't supported in mixed version clusters",
                          []})
    end.

-ifdef(EUNIT).

response_headers_test() ->
    meck:new(ns_config, [passthrough]),
    meck:expect(ns_config, latest, fun() -> [] end),
    meck:expect(ns_config, search, fun(_, _) -> {value, []} end),
    ?assertEqual(lists:keysort(1, ?NO_CACHE_HEADERS ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([])),
    ?assertEqual(lists:keysort(1, ?NO_CACHE_HEADERS ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([{allow_cache, false}])),
    ?assertEqual(lists:keysort(1, [{"Extra", "header"}, {"Foo", "bar"}] ++
                                   ?NO_CACHE_HEADERS ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([{"Foo", "bar"}, {"Extra", "header"}])),
    ?assertEqual(lists:keysort(1, [{"Cache-Control", "max-age=30000000"}] ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([{allow_cache, true}])),
    ?assertEqual(lists:keysort( 1, [{"Cache-Control", "max-age=10"}] ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([{?CACHE_CONTROL, "max-age=10"}])),
    ?assertEqual(lists:keysort(1, [{"Cache-Control", "max-age=10"}] ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([{?CACHE_CONTROL, "max-age=10"},
                                   {allow_cache, true}])),
    ?assertEqual(lists:keysort( 1, [{"Duplicate", "first"}] ++ ?NO_CACHE_HEADERS ++ ?BASE_HEADERS ++ ?SEC_HEADERS),
                 response_headers([{"Duplicate", "first"}, {"Duplicate", "second"}])),
    meck:expect(ns_config, search, fun(_, _) -> {value, [{enabled, false}]} end),
    ?assertEqual(lists:keysort( 1, [{"Duplicate", "first"}] ++ ?NO_CACHE_HEADERS ++ ?BASE_HEADERS),
                 response_headers([{"Duplicate", "first"}, {"Duplicate", "second"}])),
    true = meck:validate(ns_config),
    meck:unload(ns_config).

-endif.
