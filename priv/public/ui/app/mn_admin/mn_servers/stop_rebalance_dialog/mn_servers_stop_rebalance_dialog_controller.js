(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersStopRebalanceDialogController', mnServersStopRebalanceDialogController)

  function mnServersStopRebalanceDialogController($scope, $uibModalInstance, mnPromiseHelper, mnServersService) {
    var vm = this;
    vm.onStopRebalance = onStopRebalance;

    function onStopRebalance() {
      mnPromiseHelper(vm, mnServersService.stopRebalance(), $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .closeFinally();
    }
  }
})();
