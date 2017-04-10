(function () {
  "use strict";

  angular
    .module("mnUserRoles")
    .controller("mnUserRolesAddDialogController", mnUserRolesAddDialogController);

  function mnUserRolesAddDialogController($scope, mnUserRolesService, $uibModalInstance, mnPromiseHelper, user, isLdapEnabled, buckets) {
    var vm = this;
    vm.user = _.clone(user) || {type: "builtin"};
    vm.userID = vm.user.id || 'New';
    vm.roles = [];
    vm.save = save;
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

      if (role.role === "admin" || role.role === "cluster_admin") {
        vm.roles.forEach(function (role1) {
          if (role1.role !== "admin" ) {
            vm.selectedRoles[getUIID(role1, 2)] = vm.selectedRoles[id];
          }
          maybeContainsSelected(role1.role, role1.bucket_name);
        });
      } else {
        if (role.bucket_name) {
          buckets.byType.names.concat("*").some(function (name) {
            return maybeContainsSelected(role.role, name);
          });
        } else {
          maybeContainsSelected(role.role);
        }
      }
    }

    function maybeContainsSelected(role, bucketName) {
      if (vm.selectedRoles[role + (bucketName ? "[" + bucketName + "]" : "")]) {
        vm.containsSelected[role + "_wrapper"] = true;
        vm.containsSelected[role.split("_")[0] + "_wrapper"] = true;
        return true;
      } else {
        vm.containsSelected[role + "_wrapper"] = false;
        vm.containsSelected[role.split("_")[0] + "_wrapper"] = false;
      }
    }

    function activate() {
      mnPromiseHelper(vm, mnUserRolesService.getRoles())
        .showSpinner()
        .onSuccess(function (roles) {
          vm.roles = roles;
          vm.rolesTree = mnUserRolesService.getRolesTree(roles);

          if (user) {
            return mnPromiseHelper(vm, mnUserRolesService.prepareUserRoles(user.roles))
              .applyToScope("selectedRoles")
              .onSuccess(function () {
                user.roles.forEach(function (role) {
                  onCheckChange(role, getUIID(role, 2));
                });
              });
          }
        });
    }

    function save() {
      if (vm.form.$invalid) {
        return;
      }
      mnPromiseHelper(vm, mnUserRolesService.addUser(vm.user, _.clone(vm.selectedRoles), user), $uibModalInstance, vm.isEditingMode)
        .showGlobalSpinner()
        .catchErrors()
        .broadcast("reloadRolesPoller")
        .closeOnSuccess()
        .showGlobalSuccess("User saved successfully!", 4000);
    }
  }
})();
