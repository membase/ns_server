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
      return $q.all([
        mnTasksDetails.get(),
        $http.get('/pools/default/remoteClusters')
      ]).then(function (resp) {
        var tasks = resp[0];
        var allReferences = resp[1].data;
        var references = _.filter(allReferences, function (cluster) { return !cluster.deleted });

        var replications = _.map(_.filter(tasks.tasks, function (task) {
          return task.type === 'xdcr';
        }), function (replication) {
          var clusterUUID = replication.id.split("/")[0];
          var cluster = _.find(references, function (cluster) {
            return cluster.uuid === clusterUUID;
          });
          var name;
          if (cluster) {
            name = '"' + cluster.name + '"';
          } else {
            cluster = _.find(allReferences, function (cluster) {
              return cluster.uuid === clusterUUID;
            });
            if (cluster) {
              // if we found cluster among rawClusters we assume it was
              // deleted
              name = 'at ' + cluster.hostname;
            } else {
              name = '"unknown"';
            }
          }

          replication.protocol = "Version " + (replication.replicationType === "xmem" ? "2" :
                                              replication.replicationType === "capi" ? "1" : "unknown");
          replication.to = 'bucket "' + replication.target.split('buckets/')[1] + '" on cluster ' + name;
          replication.humanStatus = (function (status) {
            switch (status) {
              case 'running': return 'Replicating';
              case 'paused': return 'Paused';
              default: return 'Starting Up';
            }
          })(replication.status);


          if (replication.pauseRequested && replication.status != 'paused') {
            replication.status = 'spinner';
            replication.humanStatus = 'Paused';
          }

          replication.when = replication.continuous ? "on change" : "one time sync";
          return replication;
        });

        return {
          references: references,
          replications: replications
        };
      });
    }
  }
})();
