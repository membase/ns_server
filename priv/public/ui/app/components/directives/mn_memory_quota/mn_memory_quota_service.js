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
      memoryQuotaConfig: memoryQuotaConfig,
      getFirstTimeAddedServices: getFirstTimeAddedServices
    };

    return mnMemoryQuotaService;

    function prepareClusterQuotaSettings(currentPool, displayedServices, calculateMaxMemory, calculateTotal) {
      var ram = currentPool.storageTotals.ram;
      if (calculateMaxMemory === undefined) {
        calculateMaxMemory = displayedServices.kv;
      }
      var rv = {
        calculateTotal: calculateTotal,
        displayedServices: displayedServices,
        minMemorySize: Math.max(256, Math.floor(ram.quotaUsedPerNode / IEC.Mi)),
        totalMemorySize: Math.floor(ram.total/IEC.Mi),
        memoryQuota: Math.floor(ram.quotaTotalPerNode/IEC.Mi)
      };
      if (currentPool.compat.atLeast40) {
        rv.indexMemoryQuota = currentPool.indexMemoryQuota || 256;
      }
      if (currentPool.compat.atLeast45) {
        rv.ftsMemoryQuota = currentPool.ftsMemoryQuota || 256;
      }
      if (calculateMaxMemory) {
        rv.maxMemorySize = mnHelper.calculateMaxMemorySize(ram.total / IEC.Mi);
      } else {
        rv.maxMemorySize = false;
      }

      return rv;
    }
    function getFirstTimeAddedServices(interestedServices, selectedServices, allNodes) {
      var rv = {
        count: 0
      };
      angular.forEach(interestedServices, function (interestedService) {
        if (selectedServices[interestedService] && mnMemoryQuotaService.isOnlyOneNodeWithService(allNodes, selectedServices, interestedService)) {
          rv[interestedService] = true;
          rv.count++;
        }
      });
      return rv;
    }
    function isOnlyOneNodeWithService(nodes, services, service, isTakenIntoAccountPendingEject) {
      var nodesCount = 0;
      var indexExists = _.each(nodes, function (node) {
        nodesCount += (_.indexOf(node.services, service) > -1 && !(isTakenIntoAccountPendingEject && node.pendingEject));
      });
      return nodesCount === 1 && services && (angular.isArray(services) ? (_.indexOf(services, service) > -1) : services[service]);
    }
    function memoryQuotaConfig(displayedServices, calculateMaxMemory, calculateTotal) {
      return mnPoolDefault.get().then(function (poolsDefault) {
        return mnMemoryQuotaService.prepareClusterQuotaSettings(poolsDefault, displayedServices, calculateMaxMemory, calculateTotal);
      });
    }
  }
})();
