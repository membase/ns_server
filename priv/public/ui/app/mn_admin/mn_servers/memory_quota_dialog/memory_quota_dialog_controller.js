(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersMemoryQuotaDialogController', mnServersMemoryQuotaDialogController);

  function mnServersMemoryQuotaDialogController($scope, indexSettings, $q, mnPoolDefault, $uibModalInstance, mnSettingsClusterService, memoryQuotaConfig, mnPromiseHelper, firstTimeAddedServices) {
    var vm = this;
    vm.config = memoryQuotaConfig;
    vm.isEnterprise = mnPoolDefault.latestValue().value.isEnterprise;
    vm.onSubmit = onSubmit;
    vm.initialIndexSettings = _.clone(indexSettings);
    vm.indexSettings = indexSettings;
    vm.firstTimeAddedServices = firstTimeAddedServices;

    if (indexSettings.storageMode === "") {
      vm.indexSettings.storageMode = "plasma";
    }

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var queries = [
        mnPromiseHelper(vm, mnSettingsClusterService.postPoolsDefault(vm.config))
          .catchErrors()
          .getPromise()
      ];

      if (vm.firstTimeAddedServices.index) {
        queries.push(
          mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.indexSettings))
            .catchErrors("postIndexSettingsErrors")
            .getPromise()
        );
      }
      var promise = $q.all(queries);

      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showGlobalSpinner()
        .closeOnSuccess()
        .showGlobalSuccess("Memory quota saved successfully!", 4000);
    }
  }
})();
