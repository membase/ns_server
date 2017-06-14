(function () {
  "use strict";

  angular
    .module("mnUserRoles")
    .controller("mnUserRolesAddDialogController", mnUserRolesAddDialogController);

  function mnUserRolesAddDialogController($scope, mnUserRolesService, $uibModalInstance, mnPromiseHelper, user, isLdapEnabled) {
    var vm = this;
    vm.user = _.clone(user) || {domain: "local"};
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
    vm.focusError = false;

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
        $scope.buckets.details.byType.names.forEach(function (name) {
          vm.selectedRoles[role.role + "[" + name + "]"] = vm.selectedRoles[id];
        });
      }

      var containsSelected = {};

      vm.roles.forEach(function (role1) {
        if (role.role === "admin" || role.role === "cluster_admin") {
          if (role1.role !== "admin") {
            vm.selectedRoles[getUIID(role1, 2)] = vm.selectedRoles[id];
          }
        }
        if (vm.selectedRoles[getUIID(role1, 2)]) {
          containsSelected[role1.role + "_wrapper"] = true;
          containsSelected[role1.role.split("_")[0] + "_wrapper"] = true;
        }
      });

      vm.containsSelected = containsSelected;
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
        vm.focusError = true;
        return;
      }
      if (!vm.isEditingMode && vm.user.domain !== "local") {
        delete vm.user.password;
      }
      mnPromiseHelper(vm, mnUserRolesService.addUser(vm.user, _.clone(vm.selectedRoles), vm.isEditingMode), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors(function (errors) {
          vm.focusError = !!errors;
          vm.errors = errors;
        })
        .broadcast("reloadRolesPoller")
        .closeOnSuccess()
        .showGlobalSuccess("User saved successfully!", 4000);
    }
  }
})();
