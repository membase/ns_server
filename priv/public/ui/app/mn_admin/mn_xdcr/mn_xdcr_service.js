angular.module('mnXDCRService', [
  'mnHttp',
  'mnTasksDetails',
  'mnPoolDefault'
]).factory('mnXDCRService',
  function ($q, mnHttp, mnTasksDetails, mnPoolDefault) {
    var mnXDCRService = {};

    mnXDCRService.removeExcessSettings = function (settings) {
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
    };

    mnXDCRService.saveClusterReference = function (cluster, name) {
      cluster = _.clone(cluster);
      cluster.hostname && !cluster.hostname.split(":")[1] && (cluster.hostname += ":8091");
      !cluster.encription && (cluster.certificate = '');
      return mnHttp.post('/pools/default/remoteClusters' + (name ? ("/" + encodeURIComponent(name)) : ""), cluster);
    };

    mnXDCRService.deleteClusterReference = function (name) {
      return mnHttp.delete('/pools/default/remoteClusters/' + encodeURIComponent(name));
    };

    mnXDCRService.deleteReplication = function (id) {
      return mnHttp.delete('/controller/cancelXDCR/' + encodeURIComponent(id));
    };

    mnXDCRService.getReplicationSettings = function (id) {
      return mnHttp.get("/settings/replications" + (id ? ("/" + encodeURIComponent(id)) : ""));
    };

    mnXDCRService.saveReplicationSettings = function (id, settings) {
      return mnHttp.post("/settings/replications/" + encodeURIComponent(id), settings);
    };

    mnXDCRService.postRelication = function (settings) {
      return mnHttp.post("/controller/createReplication", settings);
    };

    mnXDCRService.getReplicationState = function () {
      return $q.all([
        mnTasksDetails.get(),
        mnHttp.get('/pools/default/remoteClusters')
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
    };

    return mnXDCRService;
  });
