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
        promise = mnWizardService.getEELicense();
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

      var index_settings = mnSettingsClusterService.getIndexSettings()
      index_settings.storageMode = 'forestdb'

      mnClusterConfigurationService
        .postStats(vm.register, true).then(function () {
          mnSettingsClusterService
            .postIndexSettings(index_settings).then(function () {
              mnServersService
                .setupServices({services: 'kv,index,fts,n1ql'}).then(function () {
                  var newClusterState = mnWizardService.getNewClusterState();
                  mnClusterConfigurationService
                    .postAuth(newClusterState.user).then(function () {
                      return mnAuthService
                        .login(newClusterState.user).then(function () {
                          return $state.go('app.admin.overview');
                        })
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
