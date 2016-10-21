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
        email: '',
        firstname: '',
        lastname: '',
        company: '',
        version: (pools.implementationVersion || 'unknown')
      };

      function onSubmit() {
        if (pools.isEnterprise) {
          vm.form.agree.$setValidity('required', !!vm.register.agree);
        }
        if (vm.form.$invalid || vm.viewLoading) {
          return;
        }

        vm.register.email && mnWizardStep4Service.postEmail(vm.register);

        var promise = mnWizardStep4Service
            .postStats({sendStats: vm.sendStats})
            .then(function () {
              return $state.go('app.wizard.step5');
            });
        mnPromiseHelper(vm, promise)
          .showGlobalSpinner()
          .catchErrors();
      };
    }
})();
