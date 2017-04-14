(function () {
  "use strict";

  angular.module('mnXDCR').controller('mnXDCREditDialogController', mnXDCREditDialogController);

  function mnXDCREditDialogController($scope, $uibModalInstance, mnPromiseHelper, mnXDCRService, currentSettings, globalSettings, id, mnPoolDefault, mnPools) {
    var vm = this;

    vm.mnPoolDefault = mnPoolDefault.export;
    vm.mnPools = mnPools.export;

    vm.settings = _.extend({}, globalSettings.data, currentSettings.data);
    vm.createReplication = createReplication;

    function createReplication() {
      var promise = mnXDCRService.saveReplicationSettings(id, mnXDCRService.removeExcessSettings(vm.settings));
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors()
        .closeOnSuccess()
        .broadcast("reloadTasksPoller")
        .showGlobalSuccess("Settings saved successfully!", 4000);
    };
  }
})();
