angular.module('mnServers').controller('mnServersMemoryQuotaDialogController',
  function ($scope, $modalInstance, memoryQuotaConfig, mnMemoryQuotaService, mnPromiseHelper) {
    $scope.config = memoryQuotaConfig;

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }

      var promise = mnMemoryQuotaService.postMemory({
        memoryQuota: $scope.config.memoryQuota,
        indexMemoryQuota: $scope.config.indexMemoryQuota
      });
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    }
  });
