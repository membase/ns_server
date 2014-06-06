-module(menelaus_access_log_formatter).

-export([format_msg/2, get_datetime/1]).

-include_lib("ale/include/ale.hrl").

format_msg(#log_info{time = Time,
                     user_data = {Peer, Req, Resp}}, []) ->
    [Peer,
     " - ",
     get_auth_user(Req), " ",
     get_datetime(Time), " ",
     get_path_info(Req), " ",
     io_lib:format("~w", [Resp:get(code)]), " ",
     get_size(Resp), " ",
     get_request_header_value(Req, "Referer"), " ",
     get_request_header_value(Req, "User-agent"), "\n"].

month(1) -> "Jan";
month(2) -> "Feb";
month(3) -> "Mar";
month(4) -> "Apr";
month(5) -> "May";
month(6) -> "Jun";
month(7) -> "Jul";
month(8) -> "Aug";
month(9) -> "Sep";
month(10) -> "Oct";
month(11) -> "Nov";
month(12) -> "Dec".

get_datetime(Time) ->
    UTCTime = calendar:now_to_universal_time(Time),
    LocalTime =
        {{Year, Month, Day}, {Hour, Minute, Second}} = calendar:now_to_local_time(Time),
    Diff = calendar:datetime_to_gregorian_seconds(LocalTime) -
        calendar:datetime_to_gregorian_seconds(UTCTime),
    {PlusMinus, {TZHours, TZMinutes, _}} =
         case Diff >= 0 of
             true ->
                 {"+", calendar:seconds_to_time(Diff)};
             false ->
                 {"-", calendar:seconds_to_time(-Diff)}
         end,
    io_lib:format("[~2.10.0B/~s/~4.10.0B:~2.10.0B:~2.10.0B:~2.10.0B ~s~2.10.0B~2.10.0B]",
                  [Day, month(Month), Year, Hour, Minute, Second, PlusMinus, TZHours, TZMinutes]).

get_path_info(Req) ->
    ["\"",
     atom_to_list(Req:get(method)),
     " ",
     Req:get(path),
     " HTTP/",
     get_version(Req),
     "\""].

get_version(Req) ->
    case Req:get(version) of
        {1, 0} -> "1.0";
        {1, 1} -> "1.1";
        {0, 9} -> "0.9";
        Other ->
            string:join([integer_to_list(N) || N <- tuple_to_list(Other)], ".")
    end.

get_request_header_value(Req, Header) ->
    case Req:get_header_value(Header) of
        undefined ->
            "-";
        Value ->
            Value
    end.

get_response_header_value(Resp, Header) ->
    Headers = Resp:get(headers),
    case mochiweb_headers:get_value(Header, Headers) of
        undefined ->
            "-";
        Value ->
            Value
    end.

get_size(Resp) ->
    case get_response_header_value(Resp, "Transfer-Encoding") of
        "chunked" ->
            "chunked";
        _ ->
            get_response_header_value(Resp, "Content-Length")
    end.

get_auth_user(Req) ->
    case menelaus_auth:extract_auth(Req) of
        undefined ->
            "-";
        {token, _Token} ->
            "ui-token";
        {"", _} ->
            "-";
        {User, _} ->
            User
    end.
