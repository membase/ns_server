#!/bin/sh

user=$1
password=$2
host=$3
threshold=${4:-2147483648}

curl -X POST -u $user:$password http://$host/diag/eval -d @- <<EOF
    rpc:eval_everywhere(
      proc_lib, spawn,
      [ fun () ->
                case whereis(memory_monitor) of
                    undefined ->
                        ok;
                    Pid ->
                        error_logger:info_msg("Killing old memory monitor ~p", [Pid]),
                        catch exit(Pid, kill),
                        misc:wait_for_process(Pid, infinity)
                end,

                erlang:register(memory_monitor, self()),
                Threshold = ${threshold},

          error_logger:info_msg("Memory monitor started (pid ~p, threshold ~p)", [self(), Threshold]),

          Loop = fun (Recur) ->
                     Total = erlang:memory(total),
                     case Total > Threshold of
                         true ->
                             catch error_logger:info_msg("Total used memory ~p exceeded threshold ~p", [Total, Threshold]),
                             catch ale:sync_all_sinks(),
                             lists:foreach(
                               fun (Pid) ->
                                       try diag_handler:grab_process_info(Pid) of
                                           V ->
                                               BinBefore = proplists:get_value(binary, erlang:memory()),
                                               Res = (catch begin erlang:garbage_collect(Pid), erlang:garbage_collect(Pid), erlang:garbage_collect(Pid), erlang:garbage_collect(Pid), nothing end),
                                               BinAfter = proplists:get_value(binary, erlang:memory()),
                                               PList = V ++ [{binary_diff, BinAfter - BinBefore}, {res, Res}],
                                               error_logger:info_msg("Process ~p~n~p", [Pid, PList])
                                       catch _:_ ->
                                               ok
                                       end
                               end, erlang:processes()),
                             error_logger:info_msg("Done. Going to die"),
                             gen_event:which_handlers(error_logger),
                             catch ale:sync_all_sinks(),
                             erlang:halt("memory_monitor");
                         false ->
                             catch error_logger:info_msg("Current total memory used ~p", [Total]),
                             ok
                     end,

                     timer:sleep(5000),
                     Recur(Recur)
                 end,

          Loop(Loop)
    end ]).
EOF
