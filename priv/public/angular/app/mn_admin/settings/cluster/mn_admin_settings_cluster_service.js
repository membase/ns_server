angular.module('mnAdminSettingsClusterService').factory('mnAdminSettingsClusterService',
  function ($http, mnAdminService, mnAdminServersService) {
    var mnAdminSettingsClusterService = {};
    mnAdminSettingsClusterService.model = {};
    var model = mnAdminSettingsClusterService.model;

    var getInMegs = function (value) {
      return Math.floor(value / Math.Mi);
    };
    var setCertificate = function (certificate) {
      model.certificate = certificate;
    };
    var setError = function (errors) {
      model.errors = errors.errors;
    };

    mnAdminSettingsClusterService.getAndSetDefaultCertificate = function () {
      return $http({
        method: 'GET',
        url: '/pools/default/certificate'
      }).success(setCertificate);
    };
    mnAdminSettingsClusterService.regenerateCertificate = function () {
      return $http({
        method: 'POST',
        url: '/controller/regenerateCertificate',
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'}
      }).success(setCertificate);
    };
    mnAdminSettingsClusterService.saveVisualInternalSettings = function (settings, justValidate) {
      var params = {
        method: 'POST',
        url: '/internalSettings/visual',
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'},
        data: _.serializeData(settings)
      };

      if (!!justValidate) {
        params.url += '?just_validate=1';
        return $http(params).success(setError).error(setError);
      } else {
        return $http(params).error(setError).success(mnAdminService.runDefaultPoolsDetailsLoop);
      }
    };
    mnAdminSettingsClusterService.getAndSetVisulaSettings = function () {
      return $http({
        method: 'GET',
        url: (mnAdminService.model.details ? mnAdminService.model.details.visualSettingsUri : '/internalSettings/visual'),
      }).success(function (visualInternalSettings) {
        model.tabName = visualInternalSettings.tabName;
      });
    };


    mnAdminSettingsClusterService.initializeMnAdminSettingsClusterScope = function ($scope) {
      $scope.memoryQuota = getInMegs(mnAdminService.model.details.storageTotals.ram.quotaTotalPerNode);
      $scope.tabName = mnAdminSettingsClusterService.model.tabName;

      $scope.$watch('memoryQuota', function () {
        mnAdminSettingsClusterService.saveVisualInternalSettings({
          memoryQuota: $scope.memoryQuota,
          tabName: $scope.tabName
        }, "justValidate");
      }); //live validation of memoryQuota

      $scope.$watch(function () {
        return mnAdminService.model.details.storageTotals.ram.total /
               mnAdminService.model.nodes.onlyActive.length;
      }, function (ramTotalPerActiveNode ) {
        model.totalRam = getInMegs(ramTotalPerActiveNode);
        model.maxRamMegs = Math.max(
          getInMegs(ramTotalPerActiveNode) - 1024,
          Math.floor(ramTotalPerActiveNode * 4 / (5 * Math.Mi))
        );
      });
    };

    return mnAdminSettingsClusterService;
});