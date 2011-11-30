-module(ebucketmigrator).
-export([main/1]).

-include("ns_common.hrl").

%% @doc Called automatically by escript
-spec main(list()) -> ok.

main(["-h"]) ->
    io:format(usage());

main(Args) ->
    Opts = parse(Args, []),
    run(Opts).

usage() ->
    "Usage: ebucketmigrator -h host:port -b # -d desthost:destport~n"
        "\t-h host:port Connect to host:port~n"
        "\t-A           Use TAP acks~n"
        "\t-t           Move buckets from a server to another server~n"
        "\t-b #         Operate on vbucket number #~n"
        "\t-a auth      Try to authenticate <auth>~n"
        "\t-d host:port Send all vbuckets to this server~n"
        "\t-v           Increase verbosity~n"
        "\t-F           Flush all data on the destination~n"
        "\t-N name      Use a tap stream named \"name\"~n"
        "\t-T timeout   Terminate if nothing happened for timeout seconds~n"
        "\t-e           Run as an Erlang port~n"
        "\t-V           Validate bucket takeover~n"
        "\t-E expiry    Reset the expiry of all items to 'expiry'.~n"
        "\t-f flag      Reset the flag of all items to 'flag'.~n"
        "\t-p filename  Profile the server with output to filename.~n".


%% @doc Parse the command line arguments (in the form --key val) into
%% a proplist, exapand shorthand args
parse([], Acc) ->
    Acc;

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
parse([Else | Rest], Acc) ->
    io:format("Ignoring ~p flag~n", [Else]),
    parse(Rest, Acc).


%% @doc parse the server string into a list of hosts + ip mappings
parse_host(Server) ->
    [Host, Port] = string:tokens(Server, ":"),
    {Host, list_to_integer(Port)}.

setup_logging() ->
    {ok, _Pid} = ale_sup:start_link(),

    ok = ale:start_sink(stderr, ale_stderr_sink, []),

    lists:foreach(
      fun (Logger) ->
              ok = ale:start_logger(Logger),
              ok = ale:add_sink(Logger, stderr)
      end,
      ?LOGGERS).

%% @doc
run(Conf) ->

    process_flag(trap_exit, true),

    setup_logging(),

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
            {ok, Pid} = ebucketmigrator_srv:start_link(Host, Dest, Conf1),
            receive
                {'EXIT', Pid, normal} ->
                    ok;
                {'EXIT', Pid, {badmatch, {error, econnrefused}}} ->
                    io:format("Failed to connect to host~n");
                Else ->
                    io:format("Unknown error ~p~n", [Else])
            end,
            case ProfileFile of
                undefined ->
                    ok;
                _ ->
                    fprof:trace([stop])
            end
    end.
