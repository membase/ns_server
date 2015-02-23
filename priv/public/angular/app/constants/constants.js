angular.module('app').constant('bucketsFormConfiguration', {
  authType: 'sasl',
  name: '',
  saslPassword: '',
  bucketType: 'membase',
  evictionPolicy: 'valueOnly',
  replicaNumber: "1",
  replicaIndex: "0",
  threadsNumber: "3",
  flushEnabled: "0",
  ramQuotaMB: "0",

  uri: '/pools/default/buckets'
}).constant('knownAlerts', [
  'auto_failover_node',
  'auto_failover_maximum_reached',
  'auto_failover_other_nodes_down',
  'auto_failover_cluster_too_small',
  'ip',
  'disk',
  'overhead',
  'ep_oom_errors',
  'ep_item_commit_failed'
]);