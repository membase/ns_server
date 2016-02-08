(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersMemoryQuotaDialogController', mnServersMemoryQuotaDialogController);

  function mnServersMemoryQuotaDialogController($scope, indexSettings, $q, mnPoolDefault, $uibModalInstance, mnSettingsClusterService, memoryQuotaConfig, mnPromiseHelper) {
    var vm = this;
    vm.config = memoryQuotaConfig;
    vm.isEnterprise = mnPoolDefault.latestValue().value.isEnterprise;
    vm.onSubmit = onSubmit;
    vm.initialIndexSettigs = _.clone(indexSettings);
    vm.indexSettings = indexSettings;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = $q.all([
          mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.indexSettings))
            .catchErrors("postIndexSettingsErrors")
            .getPromise(),
          mnPromiseHelper(vm, mnSettingsClusterService.postPoolsDefault(vm.config))
            .catchErrors()
            .getPromise()
        ]);

      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .closeOnSuccess()
        .broadcast("reloadServersPoller");
    }
  }
})();
