(function () {
  "use strict";

  angular
    .module("mnUserRoles")
    .controller("mnUserRolesAddDialogController", mnUserRolesAddDialogController);

  function mnUserRolesAddDialogController($scope, mnUserRolesService, $uibModalInstance, mnPromiseHelper, user, isLdapEnabled, buckets) {
    var vm = this;
    vm.user = _.clone(user) || {type: isLdapEnabled ? "saslauthd" : "builtin"};
    vm.userID = vm.user.id || 'New';
    vm.roles = [];
    vm.save = save;
    vm.onSelect = onSelect;
    vm.isEditingMode = !!user;
    vm.isLdapEnabled = isLdapEnabled;
    vm.onCheckChange = onCheckChange;
    vm.containsSelected = {};
    vm.closedWrappers = {};
    vm.selectedRoles = {};
    vm.getUIID = getUIID;
    vm.toggleWrappers = toggleWrappers;

    activate();

    function getUIID(role, level) {
      if (level === 2) {
        return role.role + (role.bucket_name ? '[' + role.bucket_name + ']' : '');
      } else {
        if (level == 0) {
          return role[0][0].role.split("_")[0] + "_wrapper";
        } else {
          return role[0].role + "_wrapper";
        }
      }
    }

    function toggleWrappers(id, value) {
      vm.closedWrappers[id] = (value !== undefined) ? value : !vm.closedWrappers[id];
    }

    function onCheckChange(role, id) {
      if (role.bucket_name === "*") {
        buckets.byType.names.forEach(function (name) {
          vm.selectedRoles[role.role + "[" + name + "]"] = vm.selectedRoles[id];
        });
      }
      buckets.byType.names.concat("*").some(function (name) {
        return maybeContainsSelected(role.role, name);
      });
    }

    function maybeContainsSelected(role, bucketName) {
      if (vm.selectedRoles[role + "[" + bucketName + "]"]) {
        vm.containsSelected[role + "_wrapper"] = true;
        vm.containsSelected[role.split("_")[0] + "_wrapper"] = true;
        return true;
      } else {
        vm.containsSelected[role + "_wrapper"] = false;
        vm.containsSelected[role.split("_")[0] + "_wrapper"] = false;
      }
    }

    function onSelect(select) {
      select.search = "";
    }

    function activate() {
      var promise = mnPromiseHelper(vm, mnUserRolesService.getRolesTree())
          .showSpinner()
          .applyToScope("rolesTree");

      if (user) {
        mnPromiseHelper(vm, mnUserRolesService.getRolesByRole(user.roles, true))
          .onSuccess(function (selectedRoles) {
            vm.selectedRoles = selectedRoles;
            user.roles.forEach(function (role) {
              if (role.bucket_name) {
                maybeContainsSelected(role.role, role.bucket_name);
              }
            });
          });
      }
    }

    function save() {
      mnPromiseHelper(vm, mnUserRolesService.addUser(vm.user, vm.selectedRoles, user), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors()
        .broadcast("reloadRolesPoller")
        .closeOnSuccess()
        .showGlobalSuccess("User saved successfully!", 4000);
    }
  }
})();
