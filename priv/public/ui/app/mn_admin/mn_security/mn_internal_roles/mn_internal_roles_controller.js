(function () {
  "use strict";

  angular
    .module("mnInternalRoles", [
      "mnInternalRolesService",
      "mnPromiseHelper",
      "mnHelper",
      "mnSpinner",
      "mnAutocompleteOff"
    ])
    .controller("mnInternalRolesController", mnInternalRolesController);

  function mnInternalRolesController($scope, $uibModal, mnInternalRolesService, mnPromiseHelper, mnHelper) {
    var vm = this;

    vm.creds = {};

    vm.createUser = createUser;
    vm.deleteUser = deleteUser;
    vm.resetUserPassword = resetUserPassword;

    activate();

    function deleteUser() {
      return $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_internal_roles/delete/mn_internal_roles_delete.html',
        controller: 'mnInternalRolesDeleteController as internalRolesDeleteCtl',
        resolve: {
          name: mnHelper.wrapInFunction(vm.roAdminName)
        }
      });
    }
    function resetUserPassword() {
      return $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_internal_roles/reset/mn_internal_roles_reset.html',
        controller: 'mnInternalRolesResetController as internalRolesResetCtl'
      });
    }
    function createUser() {
      if (vm.viewLoading) {
        return;
      }

      mnPromiseHelper(vm, mnInternalRolesService.postReadOnlyAdminName(vm.creds, true))
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .showGlobalSuccess("User created successfully!", 4000)
        .onSuccess(function () {
          mnPromiseHelper(vm, mnInternalRolesService.postReadOnlyAdminName(vm.creds))
            .reloadState();
        });
    }
    function activate() {
      mnPromiseHelper(vm, mnInternalRolesService.getAccountManagmentState())
        .showSpinner()
        .applyToScope("roAdminName");
    }
  }
})();
