(function () {
  "use strict";

  angular
    .module("mnExternalRoles", [
      "mnExternalRolesService",
      "mnHelper",
      "mnPromiseHelper",
      "mnPoll",
      "mnSortableTable",
      "mnSpinner",
      "ui.select",
      "mnLdapService"
    ])
    .controller("mnExternalRolesController", mnExternalRolesController);

  function mnExternalRolesController($scope, $uibModal, mnLdapService, mnPromiseHelper, mnExternalRolesService, mnPoller, mnHelper, mnSortableTable) {
    var vm = this;
    vm.addUser = addUser;
    vm.deleteUser = deleteUser;
    vm.editUser = editUser;
    vm.sortableTableProperties = mnSortableTable.get();
    vm.toggleSaslauthdAuth = toggleSaslauthdAuth;
    vm.getRoleFromRoles = mnExternalRolesService.getRoleFromRoles;
    vm.rolesFilter = rolesFilter;

    activate();

    function rolesFilter(value) {
      return !value.bucket_name || value.bucket_name === "*";
    }

    function activate() {
      mnPromiseHelper(vm, mnLdapService.getSaslauthdAuth())
        .applyToScope("saslauthdAuth")
        .showSpinner("saslauthdAuthLoading");

      mnPromiseHelper(vm, mnExternalRolesService.getRoles())
        .applyToScope(function (roles) {
          vm.roles = roles;
          mnPromiseHelper(vm, mnExternalRolesService.getRolesByRole(roles))
            .applyToScope("rolesByRole");
        });

      var poller = new mnPoller($scope, mnExternalRolesService.getState)
        .subscribe("state", vm)
        .setInterval(10000)
        .reloadOnScopeEvent("reloadRolesPoller", vm)
        .cycle();
    }

    function toggleSaslauthdAuth() {
      var config = {
        enabled: !vm.saslauthdAuth.enabled
      };
      mnPromiseHelper(vm, mnLdapService.postSaslauthdAuth(config))
        .applyToScope("saslauthdAuth")
        .showSpinner("saslauthdAuthLoading");
    }

    function editUser(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_external_roles/add_dialog/mn_external_roles_add_dialog.html',
        controller: 'mnExternalRolesAddDialogController as externalRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
    function addUser() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_external_roles/add_dialog/mn_external_roles_add_dialog.html',
        controller: 'mnExternalRolesAddDialogController as externalRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(undefined)
        }
      });
    }
    function deleteUser(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_external_roles/delete_dialog/mn_external_roles_delete_dialog.html',
        controller: 'mnExternalRolesDeleteDialogController as externalRolesDeleteDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
  }
})();
