angular.module('mnSettingsCluster').controller('mnSettingsClusterController',
  function ($scope, mnSettingsClusterService, nodes, poolDefault, defaultCertificate, getVisulaSettings, mnHelper) {
    $scope.focusMe = true;

    $scope.formData = {};
    $scope.formData.tabName = getVisulaSettings.data.tabName;
    $scope.formData.memoryQuota = getInMegs(poolDefault.storageTotals.ram.quotaTotalPerNode);
    $scope.totalRam = getInMegs(nodes.ramTotalPerActiveNode);
    $scope.maxRamMegs = Math.max(getInMegs(nodes.ramTotalPerActiveNode) - 1024, Math.floor(nodes.ramTotalPerActiveNode * 4 / (5 * Math.Mi)));
    setCertificate(defaultCertificate.data);

    var liveValidation = _.debounce(function () {
      mnSettingsClusterService.visualInternalSettingsValidation($scope.formData).error(setError).success(setError);
    }, 500);

    $scope.$watch('formData.memoryQuota', liveValidation);

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
      var promise = mnSettingsClusterService.saveVisualInternalSettings($scope.formData).success(mnHelper.reloadState).error(setError);
      mnHelper.handleSpinner($scope, 'settingsClusterLoaded', promise);
    };
    $scope.regenerateCertificate = function () {
      var promise = mnSettingsClusterService.regenerateCertificate().success(setCertificate);
      mnHelper.handleSpinner($scope, 'regenerateCertificateInprogress', promise);
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };
  });
