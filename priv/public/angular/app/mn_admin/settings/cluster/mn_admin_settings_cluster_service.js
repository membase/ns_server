angular.module('mnAdminSettingsClusterService').factory('mnAdminSettingsClusterService',
  function ($http, mnAdminService, mnAdminServersService, mnHttpService) {
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

    mnAdminSettingsClusterService.getAndSetDefaultCertificate = mnHttpService({
      method: 'GET',
      url: '/pools/default/certificate',
      success: [setCertificate]
    });
    mnAdminSettingsClusterService.regenerateCertificate = mnHttpService({
      method: 'POST',
      url: '/controller/regenerateCertificate',
      success: [setCertificate]
    });
    mnAdminSettingsClusterService.getAndSetVisulaSettings = mnHttpService({
      method: 'GET',
      url: '/internalSettings/visual',
      success: [function (visualInternalSettings) {
        model.tabName = visualInternalSettings.tabName;
      }]
    });

    var saveVisualInternalSettings = mnHttpService({
      method: 'POST',
      url: '/internalSettings/visual',
      error: [setError]
    });

    mnAdminSettingsClusterService.saveVisualInternalSettings = function (params) {
      return saveVisualInternalSettings(params).success(
        params.justValidate ? setError : mnAdminService.runDefaultPoolsDetailsLoop
      );
    };


    mnAdminSettingsClusterService.initializeMnAdminSettingsClusterScope = function ($scope) {
      $scope.formData = {};
      $scope.formData.memoryQuota = getInMegs(mnAdminService.model.details.storageTotals.ram.quotaTotalPerNode);
      $scope.formData.tabName = mnAdminSettingsClusterService.model.tabName;

      $scope.$watch('formData.memoryQuota', function () {
        mnAdminSettingsClusterService.saveVisualInternalSettings({
          data: $scope.formData,
          justValidate: true
        });
      }); //live validation of memoryQuota

      $scope.$watch(function () {
        return mnAdminService.model.ramTotalPerActiveNode;
      }, function (ramTotalPerActiveNode) {
        model.totalRam = getInMegs(ramTotalPerActiveNode);
        model.maxRamMegs = Math.max(
          getInMegs(ramTotalPerActiveNode) - 1024,
          Math.floor(ramTotalPerActiveNode * 4 / (5 * Math.Mi))
        );
      });
    };

    return mnAdminSettingsClusterService;
});