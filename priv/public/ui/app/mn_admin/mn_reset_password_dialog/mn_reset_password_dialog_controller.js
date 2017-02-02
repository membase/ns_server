(function () {
  "use strict";

  angular
    .module("mnResetPasswordDialog", [
      "mnResetPasswordDialogService",
      "mnAuthService",
      "mnFilters",
      "mnEqual"
    ])
    .controller("mnResetPasswordDialogController", mnResetPasswordDialogController);

  function mnResetPasswordDialogController($scope, mnResetPasswordDialogService, mnPromiseHelper, mnAuthService) {
    var vm = this;
    vm.submit = submit;
    vm.user = {};

    function submit() {
      var promise = mnAuthService.whoami().then(function (user) {
        vm.user.name = user.id;
        return mnResetPasswordDialogService.post(vm.user);
      });

      mnPromiseHelper(vm, promise)
        .showGlobalSpinner()
        .catchErrors()
        .onSuccess(function () {
          return mnAuthService.logout();
        });
    }
  }
})();
