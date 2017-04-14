(function () {
  "use strict";

  angular.module('mnXDCRService', [
    'mnTasksDetails',
    'mnPoolDefault',
    'mnFilters'
  ]).factory('mnXDCRService', mnXDCRServiceFactory);

  function mnXDCRServiceFactory($q, $http, mnTasksDetails, mnPoolDefault, mnPools, getStringBytesFilter) {
    var mnXDCRService = {
      removeExcessSettings: removeExcessSettings,
      saveClusterReference: saveClusterReference,
      deleteClusterReference: deleteClusterReference,
      deleteReplication: deleteReplication,
      getReplicationSettings: getReplicationSettings,
      saveReplicationSettings: saveReplicationSettings,
      postRelication: postRelication,
      getReplicationState: getReplicationState,
      validateRegex: validateRegex
    };

    return mnXDCRService;

    function doValidateOnOverLimit(text) {
      return getStringBytesFilter(text) > 250;
    }

    function validateRegex(regex, testKey) {
      if (doValidateOnOverLimit(regex)) {
        return $q.reject('Regex should not have size more than 250 bytes');
      }
      if (doValidateOnOverLimit(testKey)) {
        return $q.reject('Test key should not have size more than 250 bytes');
      }
      return $http({
        method: 'POST',
        mnHttp: {
          cancelPrevious: true
        },
        data: {
          expression: regex,
          keys: JSON.stringify([testKey])
        },
        transformResponse: function (data) {
          //angular expect response in JSON format
          //but server returns with text message in case of error
          var resp;

          try {
            resp = JSON.parse(data);
          } catch (e) {
            resp = data;
          }

          return resp;
        },
        url: '/_goxdcr/regexpValidation'
      });
    }

    function removeExcessSettings(settings) {
      var neededProperties = ["replicationType", "optimisticReplicationThreshold", "failureRestartInterval", "docBatchSizeKb", "workerBatchSize", "checkpointInterval", "type", "toBucket", "toCluster", "fromBucket"];
      if (mnPoolDefault.export.goxdcrEnabled) {
        neededProperties = neededProperties.concat(["sourceNozzlePerNode", "targetNozzlePerNode", "statsInterval", "logLevel"]);
      } else {
        neededProperties = neededProperties.concat(["maxConcurrentReps", "workerProcesses"]);
      }
      if (mnPools.export.isEnterprise &&
          mnPoolDefault.export.compat.atLeast50 &&
          mnPoolDefault.export.goxdcrEnabled &&
          settings.type === "xmem"
         ) {
        neededProperties.push("networkUsageLimit");
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
      if (!cluster.demandEncryption) {
        delete cluster.certificate;
        delete cluster.demandEncryption;
        delete cluster.encryptionType;
      }
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
