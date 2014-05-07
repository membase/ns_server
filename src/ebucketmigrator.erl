-module(ebucketmigrator).
-export([main/1]).

-include("ns_common.hrl").

%% @doc Called automatically by escript
-spec main(list()) -> ok.

main(["-h"]) ->
    io:format(usage());

main(["--help"]) ->
    io:format(usage());

main(Args) ->
    Opts = parse(Args, []),
    run(Opts).

usage() ->
    "Usage: ebucketmigrator -h host:port -b # -d desthost:destport~n"
        "\t-h host:port Connect to host:port~n"
        %% "\t-A           Use TAP acks~n"
        "\t-t           Move buckets from a server to another server (same as -V)~n"
        "\t-b #         Operate on vbucket number #~n"
        "\t-a auth      Try to authenticate as user <auth> (password is then read from stdin)~n"
        "\t--password password Use given password instead of reading it from stdin~n"
        "\t-d host:port Send all vbuckets to this server~n"
        "\t--bucket-name name send select_bucket on both ends before proceeding~n"
        "\t              (normally not needed with auth)~n"
        "\t-v           set loglevel to debug~n"
        %% "\t-F           Flush all data on the destination~n"
        %% "\t-N name      Use a tap stream named \"name\"~n"
        "\t-T timeout   Terminate if nothing happened for timeout seconds~n"
        %% "\t-e           Run as an Erlang port~n"
        "\t-V           Validate bucket takeover~n"
        %% "\t-E expiry    Reset the expiry of all items to 'expiry'.~n"
        %% "\t-f flag      Reset the flag of all items to 'flag'.~n"
        "\t-p filename  Profile the server with output to filename.~n".


%% @doc Parse the command line arguments (in the form --key val) into
%% a proplist, exapand shorthand args
parse([], Acc) ->
    Acc;

parse(["-t" | Rest], Acc) ->
    parse(Rest, [{takeover, true} | Acc]);
parse(["-V" | Rest], Acc) ->
    parse(Rest, [{takeover, true} | Acc]);
parse(["-v" | Rest], Acc) ->
    parse(Rest, [{verbose, true} | Acc]);
parse(["-T", Timeout | Rest], Acc) ->
    parse(Rest, [{timeout, list_to_integer(Timeout) * 1000} | Acc]);
parse(["-h", Host | Rest], Acc) ->
    parse(Rest, [{host, parse_host(Host)} | Acc]);
parse(["-d", Host | Rest], Acc) ->
    parse(Rest, [{destination, parse_host(Host)} | Acc]);
parse(["-b", VBucketsStr | Rest], Acc) ->
    VBuckets = [list_to_integer(X) || X <- string:tokens(VBucketsStr, ",")],
    parse(Rest, [{vbuckets, VBuckets} | Acc]);
parse(["-p", ProfileFile | Rest], Acc) ->
    parse(Rest, [{profile_file, ProfileFile} | Acc]);
parse(["-a", AuthUser | Rest], Acc) ->
    parse(Rest, [{username, AuthUser} | Acc]);
parse(["--bucket-name", Bucket | Rest], Acc) ->
    parse(Rest, [{bucket, Bucket} | Acc]);
parse(["--password", Pwd | Rest], Acc) ->
    parse(Rest, [{password, Pwd} | Acc]);
parse([Else | Rest], Acc) ->
    io:format("Ignoring ~p flag~n", [Else]),
    parse(Rest, Acc).


%% @doc parse the server string into a list of hosts + ip mappings
parse_host(Server) ->
    [Host, Port] = string:tokens(Server, ":"),
    {Host, list_to_integer(Port)}.

setup_logging(Verbose) ->
    LogLevel =
        case Verbose of
            true ->
                application:start(sasl),
                debug;
            _ -> warn
        end,
    {ok, _Pid} = ale_sup:start_link(),

    ok = ale:start_sink(stderr, ale_stderr_sink, []),

    lists:foreach(
      fun (Logger) ->
              ok = ale:start_logger(Logger, LogLevel),
              ok = ale:add_sink(Logger, stderr)
      end,
      ?LOGGERS).


%% @doc
run(Conf) ->
    process_flag(trap_exit, true),

    setup_logging(proplists:get_value(verbose, Conf)),

    Host = proplists:get_value(host, Conf),
    Dest = proplists:get_value(destination, Conf),
    VBuckets = proplists:get_value(vbuckets, Conf),
    ProfileFile = proplists:get_value(profile_file, Conf),

    TapSuffix = case proplists:get_value(takeover, Conf, false) of
                    true ->
                        [VBucket] = VBuckets,
                        integer_to_list(VBucket);
                    false ->
                        case Dest of
                            %% NOTE: undefined suffix wont work, but
                            %% undefined Dest will cause us to fail
                            %% before trying that
                            undefined -> undefined;
                            _ when is_tuple(Dest) ->
                                element(1, Dest)
                        end
                end,

    Conf1 = [{suffix, TapSuffix} | Conf],

    Conf2 = case {proplists:get_value(username, Conf1), proplists:get_value(password, Conf1)} of
                {undefined, undefined} -> Conf1;
                {_, undefined} ->
                    io:format("Reading password from stdin~n"),
                    Pwd0 = case file:read_line(standard_io) of
                               eof -> "";
                               {ok, Pwd0V} ->
                                   Pwd0V
                           end,
                    Pwd = case lists:reverse(Pwd0) of
                              [$\n | RevPrefix] ->
                                  lists:reverse(RevPrefix);
                              _ ->
                                  Pwd0
                          end,
                    [{password, Pwd} | Conf1];
                {undefined, _} ->
                    io:format("Given password but not username. I refuse to proceed"),
                    exit(no_username);
                {_,_} ->
                    Conf1
            end,

    case {Host, Dest, VBuckets} of
        {undefined, _, _} ->
            io:format("You need to specify the host to migrate data from~n");
        {_, undefined, _} ->
            io:format("Can't perform bucket migration without a destination host~n");
        {_, _, undefined} ->
            io:format("Please specify the vbuckets to migrate by using -b~n");
        _Else ->
            case ProfileFile of
                undefined ->
                    ok;
                _ ->
                    ok = fprof:trace([start, {file, ProfileFile}])
            end,
            ?log_debug("Starting migrator with the following args:~n(~p,~p,~p)", [Host, Dest, Conf2]),
            {ok, Pid} = ebucketmigrator_srv:start_link(Host, Dest, Conf2),
            Success =
                receive
                    {'EXIT', Pid, normal} ->
                        true;
                    {'EXIT', Pid, {badmatch, {error, econnrefused}}} ->
                        io:format("Failed to connect to host~n"),
                        false;
                    Else ->
                        io:format("Unknown error ~p~n", [Else]),
                        false
                end,
            case ProfileFile of
                undefined ->
                    ok;
                _ ->
                    fprof:trace([stop])
            end,
            case Success of
                true ->
                    ok;
                _ ->
                    %% would like some good way to sync in-flight logs
                    %% messages. Little evil sleep will do ok here.
                    timer:sleep(200),
                    erlang:halt(1)
            end
    end.
