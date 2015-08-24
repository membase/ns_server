angular.module('mnServers').controller('mnServersMemoryQuotaDialogController',
  function ($scope, $modalInstance, mnSettingsClusterService, memoryQuotaConfig, mnPromiseHelper) {
    $scope.config = memoryQuotaConfig;

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }

      var promise = mnSettingsClusterService.postPoolsDefault($scope.config);
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    }
  });
