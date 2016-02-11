(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep6Controller', mnWizardStep6Controller);

    function mnWizardStep6Controller($scope, $q, indexSettigs, $state, pools, mnPromiseHelper, memoryQuotaConfig, mnSettingsClusterService) {
      var vm = this;
      vm.initialIndexSettigs = _.clone(indexSettigs);
      vm.indexSettings = indexSettigs;
      vm.config = memoryQuotaConfig;
      vm.onSubmit = onSubmit;
      vm.isEnterprise = pools.isEnterprise;

      function login(user) {
        $state.go('app.admin.overview');
      }

      function onSubmit() {
        if (vm.viewLoading) {
          return;
        }

        if (!vm.isEnterprise) {
          vm.indexSettings.storageMode = 'forestdb';
        }

        var promise = $q.all([
          mnPromiseHelper(vm, mnSettingsClusterService.postIndexSettings(vm.indexSettings))
            .catchErrors("postIndexSettingsErrors")
            .getPromise(),
          mnPromiseHelper(vm, mnSettingsClusterService.postPoolsDefault(vm.config))
            .catchErrors()
            .getPromise()
        ]);

        mnPromiseHelper(vm, promise)
          .showErrorsSensitiveSpinner()
          .showGlobalSuccess('This server has been associated with the cluster and will join on the next rebalance operation.')
          .getPromise()
          .then(login);
      }
    }
})();
