(function () {
  "use strict";

  angular
    .module("mnExternalRoles")
    .controller("mnExternalRolesAddDialogController", mnExternalRolesAddDialogController);

  function mnExternalRolesAddDialogController($scope, mnExternalRolesService, $uibModalInstance, mnPromiseHelper, user) {
    var vm = this;
    vm.user = _.clone(user) || {};
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
          return mnExternalRolesService.getRolseByRole(user.roles);
        }).then(function (userRolseByRole) {
          vm.roles.selected = _.filter(vm.roles, function (role) {
            return userRolseByRole[role.role] && userRolseByRole[role.role].bucket_name === role.bucket_name;
          });
        });
      }
    }

    function save(user) {
      mnPromiseHelper(vm, mnExternalRolesService.addUser(vm.user, vm.roles.selected), $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .broadcast("reloadRolesPoller")
        .closeOnSuccess();
    }
  }
})();
