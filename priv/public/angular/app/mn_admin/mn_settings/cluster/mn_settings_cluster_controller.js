angular.module('mnSettingsCluster').controller('mnSettingsClusterController',
  function ($scope, mnSettingsClusterService, nodes, poolDefault, defaultCertificate, mnHelper) {
    $scope.focusMe = true;

    $scope.formData = {};
    $scope.formData.clusterName = poolDefault.clusterName;
    $scope.formData.memoryQuota = getInMegs(poolDefault.storageTotals.ram.quotaTotalPerNode);
    $scope.totalRam = getInMegs(nodes.ramTotalPerActiveNode);
    $scope.maxRamMegs = Math.max(getInMegs(nodes.ramTotalPerActiveNode) - 1024, Math.floor(nodes.ramTotalPerActiveNode * 4 / (5 * Math.Mi)));
    setCertificate(defaultCertificate.data);

    var liveValidation = _.debounce(function () {
      var promise = mnSettingsClusterService.clusterSettingsValidation($scope.formData);
      mnHelper.promiseHelper($scope, promise).catchErrorsFromSuccess();
    }, 500);

    $scope.$watch('formData.memoryQuota', liveValidation);

    function setCertificate(certificate) {
      $scope.certificate = certificate;
    }

    function getInMegs(value) {
      return Math.floor(value / Math.Mi);
    }

    $scope.saveVisualInternalSettings = function () {
      var promise = mnSettingsClusterService.saveClusterSettings($scope.formData);
      mnHelper
        .promiseHelper($scope, promise)
        .catchErrorsFromSuccess()
        .showSpinner('settingsClusterLoaded')
        .reloadState();
    };
    $scope.regenerateCertificate = function () {
      var promise = mnSettingsClusterService.regenerateCertificate().success(setCertificate);
      mnHelper
        .promiseHelper($scope, promise)
        .showSpinner('regenerateCertificateInprogress');
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };
  });
