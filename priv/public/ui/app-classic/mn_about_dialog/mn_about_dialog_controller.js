(function () {
  "use strict";

  angular
    .module("mnAboutDialog", [
      "mnAboutDialogService",
      "mnFilters"
    ])
    .controller("mnAboutDialogController", mnAboutDialogController);

  function mnAboutDialogController($scope, mnAboutDialogService, mnPromiseHelper) {
    var vm = this;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnAboutDialogService.getState())
        .showSpinner()
        .applyToScope("state");
    }
  }
})();
