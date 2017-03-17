(function () {
  "use strict";

  angular
    .module("mnWizard")
    .controller("mnWizardWelcomeController", mnWizardWelcomeController);

  function mnWizardWelcomeController(pools, mnAboutDialogService, mnWizardService) {
    var vm = this;
    vm.showAboutDialog = mnAboutDialogService.showAboutDialog;
    vm.implementationVersion = pools.implementationVersion;
    vm.setIsNewClusterFlag = setIsNewClusterFlag;

    function setIsNewClusterFlag(value) {
      mnWizardService.getState().isNewCluster = value;
    }
  }
})();
