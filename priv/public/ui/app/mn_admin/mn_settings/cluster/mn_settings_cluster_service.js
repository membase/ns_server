(function () {
  "use strict";

  angular.module('mnSettingsClusterService', [
    'mnServersService',
    'mnPoolDefault',
    'mnMemoryQuotaService'
  ]).factory('mnSettingsClusterService', mnSettingsClusterServiceFactory);

  function mnSettingsClusterServiceFactory($http, $q, mnServersService, mnPoolDefault, mnMemoryQuotaService, IEC) {
    var mnSettingsClusterService = {
      getDefaultCertificate: getDefaultCertificate,
      regenerateCertificate: regenerateCertificate,
      postPoolsDefault: postPoolsDefault,
      getIndexSettings: getIndexSettings,
      postIndexSettings: postIndexSettings,
      getClusterState: getClusterState
    };

    return mnSettingsClusterService;

    function getDefaultCertificate() {
      return $http({
        method: 'GET',
        url: '/pools/default/certificate'
      });
    }
    function regenerateCertificate() {
      return $http({
        method: 'POST',
        url: '/controller/regenerateCertificate'
      });
    }
    function postPoolsDefault(memoryQuotaConfig, justValidate, clusterName) {
      var data = {
        memoryQuota: memoryQuotaConfig.memoryQuota === null ? "" : memoryQuotaConfig.memoryQuota,
        indexMemoryQuota: memoryQuotaConfig.indexMemoryQuota === null ? "" : memoryQuotaConfig.indexMemoryQuota,
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
      return $http.get("/settings/indexes");
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
          mnMemoryQuotaService.memoryQuotaConfig(true, false),
          mnSettingsClusterService.getIndexSettings()
        ];
        if (poolDefault.isEnterprise) {
          requests.push(mnSettingsClusterService.getDefaultCertificate())
        }
        return $q.all(requests).then(function (resp) {
          var certificate = (resp[2] && resp[2].data);
          var memoryQuotaConfig = resp[0];
          var indexSettings = resp[1].data;

          return {
            initialMemoryQuota: memoryQuotaConfig.indexMemoryQuota,
            clusterName: poolDefault.clusterName,
            memoryQuotaConfig: memoryQuotaConfig,
            certificate: certificate,
            indexSettings: indexSettings
          };
        });
      });
    };
  }
})();
