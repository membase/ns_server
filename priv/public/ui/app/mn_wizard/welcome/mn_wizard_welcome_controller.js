(function () {
  "use strict";

  angular
    .module("mnWizard")
    .controller("mnWizardWelcomeController", mnWizardWelcomeController);

  function mnWizardWelcomeController(pools) {
    var vm = this;
    vm.implementationVersion = pools.implementationVersion;
  }
})();
