(function () {
  "use strict"

  angular
    .module('mnWizard')
    .controller('mnWizardStep5Controller', mnWizardStep5Controller);

    function mnWizardStep5Controller($scope, $state, mnPools, mnSettingsClusterService, mnWizardStep1Service, mnSettingsSampleBucketsService, mnWizardStep5Service, mnWizardStep2Service, mnAuthService, mnPromiseHelper, mnAlertsService) {
      var vm = this;

      vm.user = {
        username: 'Administrator',
        password: '',
        verifyPassword: ''
      };
      vm.onSubmit = onSubmit;

      activate();

      function activate() {
        vm.focusMe = true;
      }
      function login(user) {
        return mnWizardStep5Service.postAuth(user).then(function () {
          return mnAuthService.login(user).then(function () {
            if (mnWizardStep2Service.isSomeBucketSelected()) {
              mnSettingsSampleBucketsService.installSampleBuckets(mnWizardStep2Service.getSelectedBuckets()).then(null, function (resp) {
                mnAlertsService.formatAndSetAlerts(resp.data, 'error');
              });
            }
            var config = mnWizardStep1Service.getNewClusterConfig();
            if (config.services.model.index) {
              mnSettingsClusterService.postIndexSettings(config.indexSettings);
            }
          }).then(function () {
            return $state.go('app.admin.overview');
          });
        });
      }
      function onSubmit() {
        if (vm.viewLoading) {
          return;
        }

        if (vm.form.$invalid) {
          return activate();
        }

        var promise = login(vm.user);
        mnPromiseHelper(vm, promise)
          .showGlobalSpinner()
          .catchErrors();
      }
    }
})();
