(function () {
  "use strict";

  angular
    .module('mnAccountManagement')
    .controller('mnAccountManagementResetController', mnAccountManagementResetController);

  function mnAccountManagementResetController($scope, $modalInstance, mnAccountManagementService, mnPromiseHelper) {
    var vm = this;

    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnAccountManagementService.resetReadOnlyAdmin(vm.password);
      mnPromiseHelper(vm, promise, $modalInstance)
        .showSpinner()
        .cancelOnScopeDestroy($scope)
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    }
  }
})();
