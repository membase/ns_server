(function () {
  "use strict";

  angular
    .module("mnExternalRoles")
    .controller("mnExternalRolesDeleteDialogController", mnExternalRolesDeleteDialogController);

  function mnExternalRolesDeleteDialogController($scope, mnExternalRolesService, user, mnPromiseHelper, $uibModalInstance) {
    var vm = this;
    vm.username = user.id;
    vm.onSubmit = onSubmit;

    function onSubmit() {
      mnPromiseHelper(vm, mnExternalRolesService.deleteUser(user), $uibModalInstance)
        .showGlobalSpinner()
        .closeFinally()
        .broadcast("reloadRolesPoller");
    }
  }
})();
