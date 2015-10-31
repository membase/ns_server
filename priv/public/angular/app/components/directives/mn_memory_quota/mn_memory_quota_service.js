angular.module('mnMemoryQuotaService', [
  'mnHttp',
  'mnPoolDefault',
  'mnHelper'
]).factory('mnMemoryQuotaService',
  function (mnHttp, mnPoolDefault, mnHelper) {
    var mnMemoryQuotaService = {};

    mnMemoryQuotaService.prepareClusterQuotaSettings = function (currentPool, showKVMemoryQuota, calculateMaxMemory) {
      var ram = currentPool.storageTotals.ram;
      if (calculateMaxMemory === undefined) {
        calculateMaxMemory = showKVMemoryQuota;
      }
      var rv = {
        showKVMemoryQuota: showKVMemoryQuota,
        roAdmin: false,
        showIndexMemoryQuota: true,
        minMemorySize: Math.max(256, Math.floor(ram.quotaUsedPerNode / Math.Mi)),
        totalMemorySize: false,
        memoryQuota: Math.floor(ram.quotaTotalPerNode/Math.Mi),
        indexMemoryQuota: currentPool.indexMemoryQuota || 256,
        isServicesControllsAvailable: false
      };
      if (calculateMaxMemory) {
        var nNodes = _.pluck(currentPool.nodes, function (node) {
          return node.clusterMembership === "active";
        }).length;
        var ramPerNode = Math.floor(ram.total/nNodes/Math.Mi);
        rv.maxMemorySize = mnHelper.calculateMaxMemorySize(ramPerNode);
      } else {
        rv.maxMemorySize = false;
      }

      return rv;
    };

    mnMemoryQuotaService.isOnlyOneNodeWithService = function (nodes, services, service) {

      var nodesCount = 0;
      var indexExists = _.each(nodes, function (node) {
        nodesCount += (_.indexOf(node.services, service) > -1);
      });
      return nodesCount === 1 && services && (angular.isArray(services) ? (_.indexOf(services, service) > -1) : services[service]);
    };

    mnMemoryQuotaService.memoryQuotaConfig = function (showKVMemoryQuota, calculateMaxMemory) {
      return mnPoolDefault.getFresh().then(function (poolsDefault) {
        return mnMemoryQuotaService.prepareClusterQuotaSettings(poolsDefault, showKVMemoryQuota, calculateMaxMemory);
      });
    };

    return mnMemoryQuotaService;
  });
