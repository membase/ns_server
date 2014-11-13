angular.module('mnAdminSettingsCluster').controller('mnAdminSettingsClusterController',
  function ($scope, mnAdminSettingsClusterService, nodes, poolDefault, defaultCertificate, getVisulaSettings, mnHelper) {
    $scope.focusMe = true;

    $scope.formData = {};
    $scope.formData.tabName = getVisulaSettings.data.tabName;
    $scope.formData.memoryQuota = getInMegs(poolDefault.storageTotals.ram.quotaTotalPerNode);
    $scope.totalRam = getInMegs(nodes.ramTotalPerActiveNode);
    $scope.maxRamMegs = Math.max(getInMegs(nodes.ramTotalPerActiveNode) - 1024, Math.floor(nodes.ramTotalPerActiveNode * 4 / (5 * Math.Mi)));
    setCertificate(defaultCertificate.data);

    var liveValidation = _.debounce(function () {
      mnAdminSettingsClusterService.visualInternalSettingsValidation({
        data: $scope.formData
      }).error(setError).success(setError);
    }, 500);

    $scope.$watch('formData.memoryQuota', liveValidation);

    function clusterCertificateSpinnerCtrl(state) {
      $scope.regenerateCertificateInprogress = state;
    };
    function settingsClusterLoadedCtrl(state) {
      $scope.settingsClusterLoaded = state;
    }
    function setCertificate(certificate) {
      $scope.certificate = certificate;
    }
    function setError(response) {
      $scope.errors = response.errors;
    }
    function getInMegs(value) {
      return Math.floor(value / Math.Mi);
    }

    $scope.saveVisualInternalSettings = function () {
      mnAdminSettingsClusterService.saveVisualInternalSettings({
        spinner: settingsClusterLoadedCtrl,
        data: $scope.formData
      }).success(mnHelper.reloadState).error(setError);
    };
    $scope.regenerateCertificate = function () {
      mnAdminSettingsClusterService.regenerateCertificate({
        spinner: clusterCertificateSpinnerCtrl
      }).success(setCertificate);
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };
  });
