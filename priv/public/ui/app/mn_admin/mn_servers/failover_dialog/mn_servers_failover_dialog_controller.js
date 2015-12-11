(function () {
  "use strict";

  angular
    .module('mnServers')
    .controller('mnServersFailOverDialogController', mnServersFailOverDialogController);

  function mnServersFailOverDialogController($scope, mnServersService, mnPromiseHelper, node, $uibModalInstance) {
    var vm = this;

    vm.node = node;
    vm.onSubmit = onSubmit;
    vm.isFailOverBtnDisabled = isFailOverBtnDisabled;

    activate();

    function isFailOverBtnDisabled() {
      return !vm.status || !vm.status.confirmation &&
             (vm.status.failOver === 'failOver') &&
            !(vm.status.down && !vm.status.backfill) && !vm.status.dataless;
    }

    function onSubmit() {
      var promise = mnServersService.postFailover(vm.status.failOver, node.otpNode);
      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance, vm);
    }
    function activate() {
      mnPromiseHelper(vm, mnServersService.getNodeStatuses(node.hostname))
        .showSpinner()
        .getPromise()
        .then(function (details) {
          if (details) {
            vm.status = details;
          } else {
            $uibModalInstance.close();
          }
        });
    }
  }
})();
