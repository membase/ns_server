(function () {
  "use strict";

  angular.module('mnXDCR').controller('mnXDCREditDialogController', mnXDCREditDialogController);

  function mnXDCREditDialogController($scope, $uibModalInstance, mnPromiseHelper, mnXDCRService, currentSettings, globalSettings, id) {
    var vm = this;

    vm.settings = _.extend({}, globalSettings.data, currentSettings.data);
    vm.createReplication = createReplication;

    function createReplication() {
      var promise = mnXDCRService.saveReplicationSettings(id, mnXDCRService.removeExcessSettings(vm.settings));
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .cancelOnScopeDestroy($scope)
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  }
})();
