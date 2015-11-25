(function () {
  "use strict";

  angular
    .module("mnWizard")
    .controller("mnWizardWelcomeController", mnWizardWelcomeController);

  function mnWizardWelcomeController(pools, mnAboutDialogService) {
    var vm = this;
    vm.showAboutDialog = mnAboutDialogService.showAboutDialog;
    vm.implementationVersion = pools.implementationVersion;
  }
})();
