angular.module('mnSettingsCluster', [
  'mnSettingsClusterService',
  'mnHelper',
  'mnPromiseHelper'
]).controller('mnSettingsClusterController',
  function ($scope, mnSettingsClusterService, mnHelper, mnPromiseHelper) {

    mnPromiseHelper($scope, mnSettingsClusterService.getClusterState()).applyToScope("state");

    var liveValidation = _.debounce(function () {
      var promise = mnSettingsClusterService.clusterSettingsValidation($scope.state.clusterSettings);
      mnPromiseHelper($scope, promise).catchErrorsFromSuccess();
    }, 500);

    $scope.$watch('formData.memoryQuota', liveValidation);

    $scope.saveVisualInternalSettings = function () {
      if ($scope.clusterSettingsLoading) {
        return;
      }
      var promise = mnSettingsClusterService.saveClusterSettings($scope.state.clusterSettings);
      mnPromiseHelper($scope, promise)
        .catchErrorsFromSuccess()
        .showSpinner('clusterSettingsLoading')
        .reloadState();
    };
    $scope.regenerateCertificate = function () {
      if ($scope.regenerateCertificateInprogress) {
        return;
      }
      var promise = mnSettingsClusterService.regenerateCertificate().success(function (certificate) {
        $scope.state.certificate = certificate;
      });
      mnPromiseHelper($scope, promise)
        .showSpinner('regenerateCertificateInprogress');
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });
