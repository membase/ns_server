(function () {
  "use strict";

  angular.module('mnXDCRService', [
    'mnTasksDetails',
    'mnPoolDefault'
  ]).factory('mnXDCRService', mnXDCRServiceFactory);

  function mnXDCRServiceFactory($q, $http, mnTasksDetails, mnPoolDefault) {
    var mnXDCRService = {
      removeExcessSettings: removeExcessSettings,
      saveClusterReference: saveClusterReference,
      deleteClusterReference: deleteClusterReference,
      deleteReplication: deleteReplication,
      getReplicationSettings: getReplicationSettings,
      saveReplicationSettings: saveReplicationSettings,
      postRelication: postRelication,
      getReplicationState: getReplicationState
    };

    return mnXDCRService;

    function removeExcessSettings(settings) {
      var neededProperties = ["replicationType", "optimisticReplicationThreshold", "failureRestartInterval", "docBatchSizeKb", "workerBatchSize", "checkpointInterval", "type", "toBucket", "toCluster", "fromBucket"];
      if (mnPoolDefault.latestValue().value.goxdcrEnabled) {
        neededProperties = neededProperties.concat(["sourceNozzlePerNode", "targetNozzlePerNode", "statsInterval", "logLevel"]);
      } else {
        neededProperties = neededProperties.concat(["maxConcurrentReps", "workerProcesses"]);
      }
      var rv = {};
      angular.forEach(neededProperties,  function (key) {
        rv[key] = settings[key];
      });
      return rv;
    }
    function saveClusterReference(cluster, name) {
      cluster = _.clone(cluster);
      if (cluster.encryption && !cluster.certificate) {
        return $q.reject(["certificate is missing"]);
      }
      cluster.hostname && !cluster.hostname.split(":")[1] && (cluster.hostname += ":8091");
      !cluster.encription && (cluster.certificate = '');
      return $http.post('/pools/default/remoteClusters' + (name ? ("/" + encodeURIComponent(name)) : ""), cluster);
    }
    function deleteClusterReference(name) {
      return $http.delete('/pools/default/remoteClusters/' + encodeURIComponent(name));
    }
    function deleteReplication(id) {
      return $http.delete('/controller/cancelXDCR/' + encodeURIComponent(id));
    }
    function getReplicationSettings(id) {
      return $http.get("/settings/replications" + (id ? ("/" + encodeURIComponent(id)) : ""));
    }
    function saveReplicationSettings(id, settings) {
      return $http.post("/settings/replications/" + encodeURIComponent(id), settings);
    }
    function postRelication(settings) {
      return $http.post("/controller/createReplication", settings);
    }
    function getReplicationState() {
      return $http.get('/pools/default/remoteClusters').then(function (resp) {
        var byUUID = {};
        _.forEach(resp.data, function (reference) {
          byUUID[reference.uuid] = reference;
        });
        return {
          filtered: _.filter(resp.data, function (cluster) { return !cluster.deleted }),
          all: resp.data,
          byUUID: byUUID
        };
      });
    }
  }
})();
