(function () {
  "use strict";

  angular
    .module('mnInternalRoles')
    .controller('mnInternalRolesDeleteController', mnInternalRolesDeleteController);

  function mnInternalRolesDeleteController($scope, $uibModalInstance, mnInternalRolesService, mnPromiseHelper, name) {
    var vm = this;

    vm.name = name;
    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnInternalRolesService.deleteReadOnlyAdmin();
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showSpinner()
        .showGlobalSuccess("User deleted successfully!")
        .catchGlobalErrors()
        .closeFinally()
        .reloadState();
    }
  }
})();
