angular.module('mnAdminServers').controller('mnAdminServersFailOverDialogController',
  function ($scope, mnAdminServersService, mnHelper, node, $modalInstance) {
    $scope.node = node;
    var promise = mnAdminServersService.getNodeStatuses(node.hostname);
    mnHelper.handleSpinner($scope, promise);
    promise.then(function (details) {
      if (details) {
        _.extend($scope, details);
      } else {
        $modalInstance.close();
      }
    });

    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };

    $scope.onSubmit = function () {
      mnAdminServersService.postFailover($scope.failOver, node.otpNode).then(function () {
        $modalInstance.close();
        mnHelper.reloadState();
      });
    };
  });
