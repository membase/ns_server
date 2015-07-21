angular.module('mnServers').controller('mnServersEjectDialogController',
  function ($scope, $modalInstance, node, warnings, mnHelper, mnPromiseHelper, mnServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.warningFlags = warnings;
    $scope.doEjectServer = function () {
      if (node.isNodeInactiveAdded) {
        mnPromiseHelper.handleModalAction($scope, mnServersService.ejectNode({
          otpNode: node.otpNode
        }), $modalInstance);
      } else {
        mnServersService.addToPendingEject(node);
        $modalInstance.close();
        mnHelper.reloadState();
      }
    };
  });
