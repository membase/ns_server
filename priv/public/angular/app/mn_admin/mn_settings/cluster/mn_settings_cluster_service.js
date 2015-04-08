angular.module('mnSettingsClusterService').factory('mnSettingsClusterService',
  function (mnHttp, $q, mnServersService, mnPoolDefault) {
    var mnSettingsClusterService = {};


    mnSettingsClusterService.getDefaultCertificate = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/certificate'
      });
    };
    mnSettingsClusterService.regenerateCertificate = function () {
      return mnHttp({
        method: 'POST',
        url: '/controller/regenerateCertificate'
      });
    };
    mnSettingsClusterService.saveClusterSettings = function (data) {
      return mnHttp({
        method: 'POST',
        url: '/pools/default',
        data: data
      });
    };
    mnSettingsClusterService.clusterSettingsValidation = function (data) {
      return mnHttp({
        method: 'POST',
        params: {
          just_validate: 1,
        },
        data: data,
        url: '/pools/default'
      });
    };

    function getInMegs(value) {
      return Math.floor(value / Math.Mi);
    }

    mnSettingsClusterService.getClusterState = function () {
      return $q.all([
        mnSettingsClusterService.getDefaultCertificate(),
        mnServersService.getNodes(),
        mnPoolDefault.get()
      ]).then(function (resp) {
        var certificate = resp[0].data;
        var nodes = resp[1];
        var poolDefault = resp[2];

        return {
          clusterSettings: {
            clusterName: poolDefault.clusterName,
            memoryQuota: getInMegs(poolDefault.storageTotals.ram.quotaTotalPerNode)
          },
          certificate: certificate,
          totalRam: getInMegs(nodes.ramTotalPerActiveNode),
          maxRamMegs: Math.max(getInMegs(nodes.ramTotalPerActiveNode) - 1024, Math.floor(nodes.ramTotalPerActiveNode * 4 / (5 * Math.Mi)))
        };
      });
    };

    return mnSettingsClusterService;
});