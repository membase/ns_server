(function () {
  "use strict";

  angular
    .module('mnInternalRoles')
    .controller('mnInternalRolesResetController', mnInternalRolesResetController);

  function mnInternalRolesResetController($scope, $uibModalInstance, mnInternalRolesService, mnPromiseHelper) {
    var vm = this;

    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnInternalRolesService.resetReadOnlyAdmin(vm.password);
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showSpinner()
        .catchErrors()
        .showGlobalSuccess("Password reset successfully!", 4000)
        .closeOnSuccess()
        .reloadState();
    }
  }
})();
