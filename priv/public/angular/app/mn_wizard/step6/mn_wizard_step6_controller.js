angular.module('mnWizard').controller('mnWizardStep6Controller',
  function ($scope, $state, mnPools, mnPromiseHelper, memoryQuotaConfig, mnMemoryQuotaService) {
    $scope.config = memoryQuotaConfig;

    function login(user) {
      return mnPools.getFresh().then(function () {
        $state.go('app.admin.overview');
      });
    }

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }

      var promise = mnMemoryQuotaService.postMemory({
        memoryQuota: $scope.config.memoryQuota,
        indexMemoryQuota: $scope.config.indexMemoryQuota
      });
      mnPromiseHelper($scope, promise)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .showGlobalSuccess('This server has been associated with the cluster and will join on the next rebalance operation.')
        .getPromise()
        .then(login)
    }
  });