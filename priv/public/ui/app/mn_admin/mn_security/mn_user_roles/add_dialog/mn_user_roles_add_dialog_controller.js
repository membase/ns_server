(function () {
  "use strict";

  angular
    .module("mnUserRoles")
    .controller("mnUserRolesAddDialogController", mnUserRolesAddDialogController);

  function mnUserRolesAddDialogController($scope, mnUserRolesService, $uibModalInstance, mnPromiseHelper, user) {
    var vm = this;
    vm.user = _.clone(user) || {type: "saslauthd"};
    vm.userID = vm.user.id || 'New';
    vm.roles = [];
    vm.save = save;
    vm.onSelect = onSelect;

    activate();

    function onSelect(select) {
      select.search = "";
    }

    function activate() {
      var promise = mnPromiseHelper(vm, mnUserRolesService.getRoles())
        .showSpinner()
        .applyToScope("roles")
        .getPromise();

      if (user) {
        promise.then(function () {
          return mnUserRolesService.getRolesByRole(user.roles);
        }).then(function (userRolesByRole) {
          vm.roles.selected = _.filter(vm.roles, function (role) {
            return mnUserRolesService.getRoleFromRoles(userRolesByRole, role);
          });
        });
      }
    }

    function save() {
      mnPromiseHelper(vm, mnUserRolesService.addUser(vm.user, vm.roles.selected, user), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors()
        .broadcast("reloadRolesPoller")
        .closeOnSuccess()
        .showGlobalSuccess("User saved successfully!", 4000);
    }
  }
})();
