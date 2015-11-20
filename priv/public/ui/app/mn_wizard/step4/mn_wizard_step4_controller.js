(function () {
  "use strict";

  angular
    .module('mnWizard')
    .controller('mnWizardStep4Controller', mnWizardStep4Controller);

    function mnWizardStep4Controller($scope, $state, mnWizardStep4Service, pools, mnPromiseHelper) {
      var vm = this;

      vm.isEnterprise = pools.isEnterprise;
      vm.sendStats = true;
      vm.onSubmit = onSubmit;

      vm.register = {
        version: '',
        email: '',
        firstname: '',
        lastname: '',
        company: '',
        agree: true,
        version: pools.implementationVersion || 'unknown'
      };

      function onSubmit() {
        if (vm.form.$invalid || vm.viewLoading) {
          return;
        }

        vm.register.email && mnWizardStep4Service.postEmail(vm.register);

        var promise = mnWizardStep4Service.postStats({sendStats: vm.sendStats});
        mnPromiseHelper(vm, promise)
          .showErrorsSensitiveSpinner()
          .catchErrors()
          .getPromise()
          .then(function () {
            $state.go('app.wizard.step5');
          });
      };
    }
})();
