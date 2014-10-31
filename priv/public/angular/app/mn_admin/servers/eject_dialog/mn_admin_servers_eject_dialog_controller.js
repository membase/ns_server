angular.module('mnAdminServers').controller('mnAdminServersEjectDialogController',
  function ($scope, $modalInstance, node, mnAdminServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.doEjectServer = function () {
      if (node.isNodeInactiveAdded) {
        mnAdminServersService.ejectNode({otpNode: node.otpNode}).then(mnAdminServersService.reloadServersState);
      } else {
        mnAdminServersService.addToPendingEject(node);
        mnAdminServersService.reloadServersState();
      }
      $modalInstance.close();
    };
  });
