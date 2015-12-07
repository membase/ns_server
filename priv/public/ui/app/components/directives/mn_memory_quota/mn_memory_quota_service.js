(function () {
  "use strict";

  angular
    .module('mnMemoryQuotaService', [
      'mnPoolDefault',
      'mnHelper'
    ])
    .factory('mnMemoryQuotaService', mnMemoryQuotaServiceFactory);

  function mnMemoryQuotaServiceFactory($http, mnPoolDefault, mnHelper, IEC) {
    var mnMemoryQuotaService = {
      prepareClusterQuotaSettings: prepareClusterQuotaSettings,
      isOnlyOneNodeWithService: isOnlyOneNodeWithService,
      memoryQuotaConfig: memoryQuotaConfig
    };

    return mnMemoryQuotaService;

    function prepareClusterQuotaSettings(currentPool, showKVMemoryQuota, calculateMaxMemory) {
      var ram = currentPool.storageTotals.ram;
      if (calculateMaxMemory === undefined) {
        calculateMaxMemory = showKVMemoryQuota;
      }
      var rv = {
        showKVMemoryQuota: showKVMemoryQuota,
        roAdmin: false,
        showIndexMemoryQuota: true,
        minMemorySize: Math.max(256, Math.floor(ram.quotaUsedPerNode / IEC.Mi)),
        totalMemorySize: false,
        memoryQuota: Math.floor(ram.quotaTotalPerNode/IEC.Mi),
        indexMemoryQuota: currentPool.indexMemoryQuota || 256,
        isServicesControllsAvailable: false
      };
      if (calculateMaxMemory) {
        var nNodes = _.pluck(currentPool.nodes, function (node) {
          return node.clusterMembership === "active";
        }).length;
        var ramPerNode = Math.floor(ram.total/nNodes/IEC.Mi);
        rv.maxMemorySize = mnHelper.calculateMaxMemorySize(ramPerNode);
      } else {
        rv.maxMemorySize = false;
      }

      return rv;
    }
    function isOnlyOneNodeWithService(nodes, services, service) {

      var nodesCount = 0;
      var indexExists = _.each(nodes, function (node) {
        nodesCount += (_.indexOf(node.services, service) > -1);
      });
      return nodesCount === 1 && services && (angular.isArray(services) ? (_.indexOf(services, service) > -1) : services[service]);
    }
    function memoryQuotaConfig(showKVMemoryQuota, calculateMaxMemory) {
      return mnPoolDefault.getFresh().then(function (poolsDefault) {
        return mnMemoryQuotaService.prepareClusterQuotaSettings(poolsDefault, showKVMemoryQuota, calculateMaxMemory);
      });
    }
  }
})();
