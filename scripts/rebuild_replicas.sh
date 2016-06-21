#!/bin/sh
#
# A script that drops all replicas for a particular vbucket and then recreates
# them from active copy. If vbucket was replicated using tap, then it will
# also update the replication to dcp.
#
# Use as follows:
#
#   ./rebuild_replicas.sh <username> <password> <host:rest port> <bucket> <vbucket>
#
set -e

user=$1
password=$2
host=$3
bucket=$4
vbucket=$5
sleep=${6:-10000}

curl --fail -X POST -u $user:$password http://$host/diag/eval -d @- <<EOF
Bucket = "${bucket}",
VBucket = ${vbucket},
Sleep = ${sleep},

GetChainsFromBucket =
  fun () ->
    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    {map, Map} = lists:keyfind(map, 1, Conf),
    OldChain = lists:nth(VBucket+1, Map),
    NewChain = [hd(OldChain)] ++ [undefined || _ <- tl(OldChain)],
    {OldChain, NewChain}
  end,

WaitForRebalance =
  fun (Rec) ->
    case (catch ns_orchestrator:rebalance_progress_full()) of
      not_running ->
        ok;
      _ ->
        Rec(Rec)
    end
  end,

SyncConfig =
  fun () ->
    Nodes = ns_node_disco:nodes_wanted(),

    ns_config_rep:pull_and_push(Nodes),
    ns_config:sync_announcements(),
    ok = ns_config_rep:synchronize_remote(Nodes)
  end,

Rebalance =
  fun (C) ->
    error_logger:info_msg("Starting fixup rebalance ~p", [{VBucket, C}]),

    SyncConfig(),
    ok = ns_orchestrator:ensure_janitor_run({bucket, Bucket}),
    ok = gen_fsm:sync_send_event({global, ns_orchestrator},
                                 {move_vbuckets, Bucket, [{VBucket, C}]}),
    error_logger:info_msg("Waiting for a fixup rebalance ~p to complete", [{VBucket, C}]),
    WaitForRebalance(WaitForRebalance),
    error_logger:info_msg("Fixup rebalance ~p is complete", [{VBucket, C}])
  end,

UpdateReplType =
  fun () ->
    SyncConfig(),

    {ok, Conf} = ns_bucket:get_bucket(Bucket),
    case ns_bucket:replication_type(Conf) of
      dcp ->
        ok;
      Type ->
        TapVBuckets =
          case Type of
            tap ->
              lists:seq(0, proplists:get_value(num_vbuckets, Conf) - 1);
            {dcp, Vs} ->
              Vs
          end,
        NewType =
          case ordsets:del_element(VBucket, TapVBuckets) of
            [] ->
              dcp;
            NewTapVBuckets ->
              {dcp, NewTapVBuckets}
          end,
        error_logger:info_msg("Updating replication type for bucket ~p:~n~p", [Bucket, NewType]),
        ns_bucket:update_bucket_props(Bucket, [{repl_type, NewType}]),
        ns_config:sync_announcements(),
        ok = ns_config_rep:synchronize_remote([mb_master:master_node()])
    end
  end,

{OldChain, NoReplicasChain} =
  case ns_config:search({fixup_rebalance, Bucket, VBucket}) of
    {value, Chains} ->
      error_logger:info_msg("Found unfinished fixup rebalance for ~p. Chains:~n~p", [VBucket, Chains]),
      Chains;
    false ->
      Chains = GetChainsFromBucket(),
      ns_config:set({fixup_rebalance, Bucket, VBucket}, Chains),
      Chains
  end,

Rebalance(NoReplicasChain),
UpdateReplType(),
Rebalance(OldChain),
ns_config:delete({fixup_rebalance, Bucket, VBucket}),

timer:sleep(Sleep).
EOF
