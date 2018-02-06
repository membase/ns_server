(function () {
  "use strict";

  angular.module('mnSettingsClusterService', [
    'mnPoolDefault'
  ]).factory('mnSettingsClusterService', mnSettingsClusterServiceFactory);

  function mnSettingsClusterServiceFactory($http, $q, IEC, mnPoolDefault) {
    var mnSettingsClusterService = {
      postPoolsDefault: postPoolsDefault,
      getIndexSettings: getIndexSettings,
      postIndexSettings: postIndexSettings,
      getLogRedaction: getLogRedaction,
      postLogRedaction: postLogRedaction
    };

    return mnSettingsClusterService;

    function getLogRedaction() {
      return $http.get("/settings/logRedaction").then(function (resp) {
        return resp.data;
      });
    }

    function postLogRedaction(data) {
      return $http.post("/settings/logRedaction", data);
    }

    function maybeSetQuota(data, memory, service, key) {
      if (!memory.services || memory.services.model[service]) {
        if (memory[key] === null) {
          data[key] = "";
        } else {
          data[key] = memory[key];
        }
      }
    }

    function postPoolsDefault(memoryQuotaConfig, justValidate, clusterName) {
      var data = {
        clusterName: clusterName
      };

      if (memoryQuotaConfig) {
        maybeSetQuota(data, memoryQuotaConfig, "kv", "memoryQuota");
        maybeSetQuota(data, memoryQuotaConfig, "index", "indexMemoryQuota");
        maybeSetQuota(data, memoryQuotaConfig, "fts", "ftsMemoryQuota");
      }

      if (mnPoolDefault.export.isEnterprise) {
        maybeSetQuota(data, memoryQuotaConfig, "cbas", "cbasMemoryQuota");
        maybeSetQuota(data, memoryQuotaConfig, "eventing", "eventingMemoryQuota");
      }

      var config = {
        method: 'POST',
        url: '/pools/default',
        data: data
      };
      if (justValidate) {
        config.params = {
          just_validate: 1
        };
      }
      return $http(config);
    }
    function getIndexSettings() {
      return $http.get("/settings/indexes").then(function (resp) {
        return resp.data;
      });
    }
    function postIndexSettings(data, justValidate) {
      var configData = {};
      (["indexerThreads", "logLevel", "maxRollbackPoints", "storageMode"])
        .forEach(function (name) {
          if (data[name]) {
            configData[name] = data[name];
          }
        });
      var config = {
        method: 'POST',
        url: '/settings/indexes',
        data: configData
      };
      if (justValidate) {
        config.params = {
          just_validate: 1
        };
      }
      return $http(config);
    }
  }
})();
