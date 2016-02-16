(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersMemoryQuotaDialogController', mnServersMemoryQuotaDialogController);

  function mnServersMemoryQuotaDialogController($scope, indexSettings, $q, mnPoolDefault, $uibModalInstance, mnSettingsClusterService, memoryQuotaConfig, mnPromiseHelper, servicesAddedWithSpecificSettings) {
    var vm = this;
    vm.config = memoryQuotaConfig;
    vm.isEnterprise = mnPoolDefault.latestValue().value.isEnterprise;
    vm.onSubmit = onSubmit;
    vm.initialIndexSettigs = _.clone(indexSettings);
    vm.indexSettings = indexSettings;
    vm.servicesAddedWithSpecificSettings = servicesAddedWithSpecificSettings;

    if (vm.config.displayedServices.index) {
      /* if index node is to be added, the default should be forest db */
      vm.indexSettings.storageMode = 'forestdb';
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
      if(vm.servicesAddedWithSpecificSettings.index) {
        queries.push(
          mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.indexSettings))
            .catchErrors("postIndexSettingsErrors")
            .getPromise()
        );
      }
      var promise = $q.all(queries);

      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .closeOnSuccess()
        .broadcast("reloadServersPoller");
    }
  }
})();
