(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep6Controller', mnWizardStep6Controller);

    function mnWizardStep6Controller($scope, $q, indexSettings, $state, pools, mnPromiseHelper, memoryQuotaConfig, mnSettingsClusterService, firstTimeAddedNodes) {
      var vm = this;
      vm.initialIndexSettings = _.clone(indexSettings);
      vm.indexSettings = indexSettings;
      vm.config = memoryQuotaConfig;
      vm.onSubmit = onSubmit;
      vm.firstTimeAddedNodes = firstTimeAddedNodes;
      vm.isEnterprise = pools.isEnterprise;

      if (indexSettings.storageMode === "") {
        vm.indexSettings.storageMode = "forestdb";
      }

      function login(user) {
        $state.go('app.admin.overview');
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

        if (vm.firstTimeAddedNodes.index) {
          queries.push(
            mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.indexSettings))
              .catchErrors("postIndexSettingsErrors")
              .getPromise()
          );
        }
        var promise = $q.all(queries);

        mnPromiseHelper(vm, promise)
          .showErrorsSensitiveSpinner()
          .showGlobalSuccess('This server has been associated with the cluster and will join on the next rebalance operation.')
          .getPromise()
          .then(login);
      }
    }
})();
