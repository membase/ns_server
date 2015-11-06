angular.module('mnServers').controller('mnServersMemoryQuotaDialogController',
  function ($scope, $uibModalInstance, mnSettingsClusterService, memoryQuotaConfig, mnPromiseHelper) {
    $scope.config = memoryQuotaConfig;

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }

      var promise = mnSettingsClusterService.postPoolsDefault($scope.config);
      mnPromiseHelper($scope, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .cancelOnScopeDestroy()
        .closeOnSuccess()
        .reloadState();
    }
  });
