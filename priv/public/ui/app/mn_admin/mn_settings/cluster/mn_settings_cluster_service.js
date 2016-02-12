(function () {
  "use strict";

  angular.module('mnSettingsClusterService', [
    'mnServersService',
    'mnPoolDefault',
    'mnMemoryQuotaService'
  ]).factory('mnSettingsClusterService', mnSettingsClusterServiceFactory);

  function mnSettingsClusterServiceFactory($http, $q, mnServersService, mnPoolDefault, mnMemoryQuotaService, IEC) {
    var mnSettingsClusterService = {
      postPoolsDefault: postPoolsDefault,
      getIndexSettings: getIndexSettings,
      postIndexSettings: postIndexSettings,
      getClusterState: getClusterState
    };

    return mnSettingsClusterService;

    function postPoolsDefault(memoryQuotaConfig, justValidate, clusterName) {
      var data = {
        memoryQuota: memoryQuotaConfig.memoryQuota === null ? "" : memoryQuotaConfig.memoryQuota,
        indexMemoryQuota: memoryQuotaConfig.indexMemoryQuota === null ? "" : memoryQuotaConfig.indexMemoryQuota,
        ftsMemoryQuota: memoryQuotaConfig.ftsMemoryQuota === null ? "" : memoryQuotaConfig.ftsMemoryQuota,
        clusterName: clusterName
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
      var config = {
        method: 'POST',
        url: '/settings/indexes',
        data: data
      };
      if (justValidate) {
        config.params = {
          just_validate: 1
        };
      }
      return $http(config);
    }
    function getInMegs(value) {
      return Math.floor(value / IEC.Mi);
    }
    function getClusterState() {
      return mnPoolDefault.getFresh().then(function (poolDefault) {
        var requests = [
          mnMemoryQuotaService.memoryQuotaConfig({kv: true, index: true, fts: true, n1ql: true}, false),
          mnSettingsClusterService.getIndexSettings()
        ];
        return $q.all(requests).then(function (resp) {
          var memoryQuotaConfig = resp[0];
          var indexSettings = resp[1];

          return {
            initialMemoryQuota: memoryQuotaConfig.indexMemoryQuota,
            clusterName: poolDefault.clusterName,
            memoryQuotaConfig: memoryQuotaConfig,
            indexSettings: indexSettings
          };
        });
      });
    };
  }
})();
