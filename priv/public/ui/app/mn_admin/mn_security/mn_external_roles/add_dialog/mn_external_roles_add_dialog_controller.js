(function () {
  "use strict";

  angular
    .module("mnExternalRoles")
    .controller("mnExternalRolesAddDialogController", mnExternalRolesAddDialogController);

  function mnExternalRolesAddDialogController($scope, mnExternalRolesService, $uibModalInstance, mnPromiseHelper, user) {
    var vm = this;
    vm.user = _.clone(user) || {};
    vm.userID = vm.user.id || 'New';
    vm.roles = [];
    vm.save = save;
    vm.onSelect = onSelect;

    activate();

    function onSelect(select) {
      select.search = "";
    }

    function activate() {
      var promise = mnPromiseHelper(vm, mnExternalRolesService.getRoles())
        .showSpinner()
        .applyToScope("roles")
        .getPromise();

      if (user) {
        promise.then(function () {
          return mnExternalRolesService.getRolesByRole(user.roles);
        }).then(function (userRolesByRole) {
          vm.roles.selected = _.filter(vm.roles, function (role) {
            return mnExternalRolesService.getRoleFromRoles(userRolesByRole, role);
          });
        });
      }
    }

    function save() {
      mnPromiseHelper(vm, mnExternalRolesService.addUser(vm.user, vm.roles.selected, user), $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors()
        .broadcast("reloadRolesPoller")
        .closeOnSuccess();
    }
  }
})();
