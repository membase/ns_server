(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep6Controller', mnWizardStep6Controller);

    function mnWizardStep6Controller($scope, $state, mnPools, mnPromiseHelper, memoryQuotaConfig, mnSettingsClusterService) {
      var vm = this;

      vm.config = memoryQuotaConfig;
      vm.onSubmit = onSubmit;

      function login(user) {
        return mnPools.getFresh().then(function () {
          $state.go('app.admin.overview');
        });
      }

      function onSubmit() {
        if (vm.viewLoading) {
          return;
        }

        var promise = mnSettingsClusterService.postPoolsDefault(vm.config);
        mnPromiseHelper(vm, promise)
          .showErrorsSensitiveSpinner()
          .catchErrors()
          .showGlobalSuccess('This server has been associated with the cluster and will join on the next rebalance operation.')
          .getPromise()
          .then(login);
      }
    }
})();
