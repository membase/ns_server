angular.module('mnServers').controller('mnServersMemoryQuotaDialogController',
  function ($scope, $modalInstance, memoryQuotaConfig, mnMemoryQuotaService, mnHelper) {
    $scope.config = memoryQuotaConfig;

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }

      var promise = mnMemoryQuotaService.postMemory({
        memoryQuota: $scope.config.memoryQuota,
        indexMemoryQuota: $scope.config.indexMemoryQuota
      });
      mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    }
  });
