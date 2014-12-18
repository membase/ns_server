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
});