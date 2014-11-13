angular.module('mnAdminServers').controller('mnAdminServersEjectDialogController',
  function ($scope, $modalInstance, node, mnHelper, mnAdminServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.doEjectServer = function () {
      if (node.isNodeInactiveAdded) {
        mnAdminServersService.ejectNode({otpNode: node.otpNode}).then(mnHelper.reloadState);
      } else {
        mnAdminServersService.addToPendingEject(node);
        mnHelper.reloadState();
      }
      $modalInstance.close();
    };
  });
