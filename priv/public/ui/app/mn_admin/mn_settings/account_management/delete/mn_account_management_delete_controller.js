(function () {
  "use strict";

  angular
    .module('mnAccountManagement')
    .controller('mnAccountManagementDeleteController', mnAccountManagementDeleteController);

  function mnAccountManagementDeleteController($scope, $modalInstance, mnAccountManagementService, mnPromiseHelper, name) {
    var vm = this;

    vm.name = name;
    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnAccountManagementService.deleteReadOnlyAdmin();
      mnPromiseHelper(vm, promise, $modalInstance)
        .showSpinner()
        .cancelOnScopeDestroy($scope)
        .catchGlobalErrors()
        .closeFinally()
        .reloadState();
    }
  }
})();
