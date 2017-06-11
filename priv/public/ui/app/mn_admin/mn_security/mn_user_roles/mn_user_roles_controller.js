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
      "mnEqual",
      "mnFilters",
      "mnAutocompleteOff",
      "mnFocus",
      "mnSaslauthdAuth"
    ])
    .controller("mnUserRolesController", mnUserRolesController);

  function mnUserRolesController($scope, $uibModal, mnLdapService, mnPromiseHelper, mnUserRolesService, mnPoller, mnHelper, $state, poolDefault) {
    var vm = this;
    vm.addUser = addUser;
    vm.deleteUser = deleteUser;
    vm.editUser = editUser;
    vm.resetUserPassword = resetUserPassword;

    vm.rolesFilter = rolesFilter;
    vm.filterField = "";

    vm.isLdapEnabled = poolDefault.ldapEnabled;

    vm.pageSize = $state.params.pageSize;
    vm.pageSizeChanged = pageSizeChanged;
    vm.listFiter = listFiter;

    activate();

    function listFiter(user) {
      var interestingFields = ["id", "name"];
      var l1 = user.roles.length;
      var l2 = interestingFields.length;
      var i1;
      var i2;
      var searchValue = vm.filterField.toLowerCase();
      var role;
      var roleName;
      var rv = false;
      var searchFiled;

      if ((user.domain === "local" ? "Couchbase" : "External")
          .toLowerCase()
          .indexOf(searchValue) > -1) {
        rv = true;
      }

      if (!rv) {
        //look in roles
        loop1:
        for (i1 = 0; i1 < l1; i1++) {
          role = user.roles[i1];
          roleName = role.role + (role.bucket_name ? '[' + role.bucket_name + ']' : '');
          if (vm.rolesByRole[roleName].name.toLowerCase().indexOf(searchValue) > -1) {
            rv = true;
            break loop1;
          }
        }
      }

      if (!rv) {
        //look in interestingFields
        loop2:
        for (i2 = 0; i2 < l2; i2++) {
          searchFiled = interestingFields[i2];
          if (user[searchFiled].toLowerCase().indexOf(searchValue) > -1) {
            rv = true;
            break loop2;
          }
        }
      }

      return rv;
    }

    function pageSizeChanged() {
      $state.go('.', {
        pageSize: vm.pageSize
      });
    }

    function rolesFilter(value) {
      return !value.bucket_name || value.bucket_name === "*";
    }

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedUsers', '.');

      mnPromiseHelper(vm, mnUserRolesService.getRoles())
        .applyToScope(function (roles) {
          vm.roles = roles;
          mnPromiseHelper(vm, mnUserRolesService.getRolesByRole(roles))
            .applyToScope("rolesByRole");
        });

      var poller = new mnPoller($scope, function () {
        return mnUserRolesService.getState($state.params);
      })
          .subscribe("state", vm)
          .setInterval(10000)
          .reloadOnScopeEvent("reloadRolesPoller")
          .cycle();
    }

    function editUser(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/add_dialog/mn_user_roles_add_dialog.html',
        controller: 'mnUserRolesAddDialogController as userRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user),
          isLdapEnabled: mnHelper.wrapInFunction(poolDefault.ldapEnabled)
        }
      });
    }
    function addUser() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/add_dialog/mn_user_roles_add_dialog.html',
        controller: 'mnUserRolesAddDialogController as userRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(undefined),
          isLdapEnabled: mnHelper.wrapInFunction(poolDefault.ldapEnabled)
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
