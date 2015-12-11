(function () {
  "use strict";

  angular
    .module('mnAccountManagement')
    .controller('mnAccountManagementResetController', mnAccountManagementResetController);

  function mnAccountManagementResetController($scope, $uibModalInstance, mnAccountManagementService, mnPromiseHelper) {
    var vm = this;

    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnAccountManagementService.resetReadOnlyAdmin(vm.password);
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    }
  }
})();
