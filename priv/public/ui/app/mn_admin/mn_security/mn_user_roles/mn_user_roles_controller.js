(function () {
  "use strict";

  angular
    .module("mnUserRoles", [
      "mnUserRolesService",
      "mnHelper",
      "mnPromiseHelper",
      "mnPoll",
      "mnSortableTable",
      "mnSpinner",
      "ui.select",
      "mnLdapService",
      "mnEqual"
    ])
    .controller("mnUserRolesController", mnUserRolesController);

  function mnUserRolesController($scope, $uibModal, mnLdapService, mnPromiseHelper, mnUserRolesService, mnPoller, mnHelper) {
    var vm = this;
    vm.addUser = addUser;
    vm.deleteUser = deleteUser;
    vm.editUser = editUser;
    vm.resetUserPassword = resetUserPassword;

    vm.toggleSaslauthdAuth = toggleSaslauthdAuth;
    vm.getRoleFromRoles = mnUserRolesService.getRoleFromRoles;
    vm.rolesFilter = rolesFilter;

    activate();

    function rolesFilter(value) {
      return !value.bucket_name || value.bucket_name === "*";
    }

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedUsers', 'app.admin.security.userRoles');

      mnPromiseHelper(vm, mnLdapService.getSaslauthdAuth())
        .applyToScope("saslauthdAuth")
        .showSpinner("saslauthdAuthLoading");

      mnPromiseHelper(vm, mnUserRolesService.getRoles())
        .applyToScope(function (roles) {
          vm.roles = roles;
          mnPromiseHelper(vm, mnUserRolesService.getRolesByRole(roles))
            .applyToScope("rolesByRole");
        });

      var poller = new mnPoller($scope, mnUserRolesService.getState)
        .subscribe("state", vm)
        .setInterval(10000)
        .reloadOnScopeEvent("reloadRolesPoller")
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
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/add_dialog/mn_user_roles_add_dialog.html',
        controller: 'mnUserRolesAddDialogController as userRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
    function addUser() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/add_dialog/mn_user_roles_add_dialog.html',
        controller: 'mnUserRolesAddDialogController as userRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(undefined)
        }
      });
    }
    function resetUserPassword(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/reset_password_dialog/mn_user_roles_reset_password_dialog.html',
        controller: 'mnUserRolesResetPasswordDialogController as userRolesResetPasswordDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
    function deleteUser(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/delete_dialog/mn_user_roles_delete_dialog.html',
        controller: 'mnUserRolesDeleteDialogController as userRolesDeleteDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
  }
})();
