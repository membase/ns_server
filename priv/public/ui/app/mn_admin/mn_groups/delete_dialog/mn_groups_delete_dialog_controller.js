(function () {
  "use strict";

  angular
    .module('mnGroups')
    .controller('mnGroupsDeleteDialogController', mnGroupsDeleteDialogController);

  function mnGroupsDeleteDialogController($scope, $modalInstance, mnGroupsService, mnPromiseHelper, group) {
    var vm = this;

    vm.onSubmit = onSubmit;

    function onSubmit() {
      if (vm.viewLoading) {
        return;
      }

      var promise = mnGroupsService.deleteGroup(group.uri);
      mnPromiseHelper(vm, promise, $modalInstance)
        .showSpinner()
        .catchErrors()
        .closeFinally()
        .reloadState();
    }
  }
})();
