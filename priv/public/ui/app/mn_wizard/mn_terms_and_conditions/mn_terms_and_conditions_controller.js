(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnTermsAndConditionsController', mnTermsAndConditionsController);

  function mnTermsAndConditionsController($scope, $state, mnWizardService, pools, mnPromiseHelper, mnClusterConfigurationService, mnSettingsClusterService, mnAuthService, mnServersService ) {
    var vm = this;

    vm.isEnterprise = pools.isEnterprise;
    vm.onSubmit = onSubmit;
    vm.finishWithDefault = finishWithDefault;


    mnWizardService.getTermsAndConditionsState().version = (pools.implementationVersion || 'unknown');
    vm.register = mnWizardService.getTermsAndConditionsState();
    activate();
    function activate() {
      var promise;
      if (vm.isEnterprise) {
        promise = mnWizardService.getEELicense();
      } else {
        promise = mnWizardService.getCELicense();
      }

      mnPromiseHelper(vm, promise)
        .showSpinner()
        .applyToScope("license");

    }

    function finishWithDefault() {
      vm.form.agree.$setValidity('required', !!vm.agree);

      if (vm.form.$invalid) {
        return;
      }

      mnClusterConfigurationService
        .postStats(vm.register, true).then(function () {
          var setupServicesPromise =
              mnServersService.setupServices({
                services: 'kv,index,fts,n1ql',
                setDefaultMemQuotas : true
              });

          mnPromiseHelper(vm, setupServicesPromise)
            .catchErrors()
            .onSuccess(function () {
              var newClusterState = mnWizardService.getNewClusterState();
              mnSettingsClusterService.postIndexSettings({storageMode: vm.isEnterprise ? "plasma" : "forestdb"});
              mnSettingsClusterService
                .postPoolsDefault(false, false, newClusterState.clusterName).then(function () {
                  mnClusterConfigurationService
                    .postAuth(newClusterState.user).then(function () {
                      return mnAuthService
                        .login(newClusterState.user).then(function () {
                          return $state.go('app.admin.overview');
                        });
                    });
                });
            });
        });
    }

    function onSubmit() {
      vm.form.agree.$setValidity('required', !!vm.agree);

      if (vm.form.$invalid) {
        return;
      }
      $state.go('app.wizard.clusterConfiguration');
    }
  }
})();
