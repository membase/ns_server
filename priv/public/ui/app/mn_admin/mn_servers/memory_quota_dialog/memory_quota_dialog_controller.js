(function () {
  angular
    .module('mnServers')
    .controller('mnServersMemoryQuotaDialogController', mnServersMemoryQuotaDialogController);

  function mnServersMemoryQuotaDialogController($scope, $uibModalInstance, mnSettingsClusterService, memoryQuotaConfig, mnPromiseHelper) {
    var vm = this;
    vm.config = memoryQuotaConfig;

    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnSettingsClusterService.postPoolsDefault(vm.config);
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .cancelOnScopeDestroy($scope)
        .closeOnSuccess();
    }
  }
})();
