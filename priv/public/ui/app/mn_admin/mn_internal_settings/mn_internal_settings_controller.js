(function () {
  "use strict";

  angular
    .module("mnInternalSettings", [
      "mnInternalSettingsService",
      "mnPromiseHelper",
      "mnSpinner"
    ])
    .controller("mnInternalSettingsController", mnInternalSettingsController);

  function mnInternalSettingsController($scope, mnInternalSettingsService, mnPromiseHelper, mnPoolDefault, $uibModalInstance) {
    var vm = this;

    vm.onSubmit = onSubmit;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    activate();

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }
      mnPromiseHelper(vm, mnInternalSettingsService.save(vm.state), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    }

    function activate() {
      mnPromiseHelper(vm, mnInternalSettingsService.getState())
        .showSpinner()
        .applyToScope("state");
    }
  }
})();
