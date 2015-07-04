angular.module('mnMemoryQuotaService', [
  'mnHttp',
  'mnPoolDefault'
]).factory('mnMemoryQuotaService',
  function (mnHttp, mnPoolDefault) {
    var mnMemoryQuotaService = {};

    mnMemoryQuotaService.prepareClusterQuotaSettings = function (currentPool) {
      var nNodes = 0;
      var ram = currentPool.storageTotals.ram;
      angular.forEach(currentPool.nodes, function (node) {
        if (node.clusterMembership === "active") {
          nNodes++;
        }
      });

      var ramPerNode = Math.floor(ram.total/nNodes/Math.Mi);
      var minMemorySize = Math.max(256, Math.floor(ram.quotaUsedPerNode / Math.Mi));

      return {
        showIndexMemoryQuota: true,
        minMemorySize: minMemorySize,
        totalMemorySize: ramPerNode,
        maxMemorySize: Math.floor(ramPerNode / 100 * 80),
        memoryQuota: Math.floor(ram.quotaTotalPerNode/Math.Mi),
        indexMemoryQuota: currentPool.indexMemoryQuota || 256
      };
    };

    mnMemoryQuotaService.isOnlyOneNodeWithService = function (nodes, services, service) {
      var nodesCount = 0;
      var indexExists = _.each(nodes, function (node) {
        nodesCount += (_.indexOf(node.services, service) > -1);
      });
      return nodesCount === 1 && services[service];
    };

    mnMemoryQuotaService.postMemory = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/pools/default',
        data: data
      });
    };

    mnMemoryQuotaService.memoryQuotaConfig = function (showKVMemoryQuota) {
      return mnPoolDefault.get().then(function (poolsDefault) {
        var rv = mnMemoryQuotaService.prepareClusterQuotaSettings(poolsDefault);
        rv.showKVMemoryQuota = showKVMemoryQuota;
        rv.showTotalPerNode = rv.showKVMemoryQuota;
        return rv;
      });
    };

    return mnMemoryQuotaService;
  });
