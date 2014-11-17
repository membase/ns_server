angular.module('mnServers').controller('mnServersEjectDialogController',
  function ($scope, $modalInstance, node, mnHelper, mnServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.doEjectServer = function () {
      if (node.isNodeInactiveAdded) {
        mnServersService.ejectNode({otpNode: node.otpNode}).then(mnHelper.reloadState);
      } else {
        mnServersService.addToPendingEject(node);
        mnHelper.reloadState();
      }
      $modalInstance.close();
    };
  });
