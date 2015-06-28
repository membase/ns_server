angular.module('mnSettingsCluster', [
  'mnSettingsClusterService',
  'mnHelper'
]).controller('mnSettingsClusterController',
  function ($scope, mnSettingsClusterService, clusterState, mnHelper) {
    $scope.state = clusterState;

    var liveValidation = _.debounce(function () {
      var promise = mnSettingsClusterService.clusterSettingsValidation($scope.state.clusterSettings);
      mnHelper.promiseHelper($scope, promise).catchErrorsFromSuccess();
    }, 500);

    $scope.$watch('formData.memoryQuota', liveValidation);

    $scope.saveVisualInternalSettings = function () {
      if ($scope.clusterSettingsLoading) {
        return;
      }
      var promise = mnSettingsClusterService.saveClusterSettings($scope.state.clusterSettings);
      mnHelper
        .promiseHelper($scope, promise)
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
      mnHelper
        .promiseHelper($scope, promise)
        .showSpinner('regenerateCertificateInprogress');
    };
    $scope.toggleCertArea = function () {
      $scope.toggleCertAreaFlag = !$scope.toggleCertAreaFlag;
    };
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });
