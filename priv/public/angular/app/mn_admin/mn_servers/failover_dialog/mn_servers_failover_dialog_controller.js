angular.module('mnServers').controller('mnServersFailOverDialogController',
  function ($scope, mnServersService, mnHelper, node, $modalInstance) {
    $scope.node = node;
    var promise = mnServersService.getNodeStatuses(node.hostname);
    mnHelper.handleSpinner($scope, promise);
    promise.then(function (details) {
      if (details) {
        $scope.status = details;
      } else {
        $modalInstance.close();
      }
    });

    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };

    $scope.onSubmit = function () {
      mnServersService.postFailover($scope.failOver, node.otpNode).then(function () {
        $modalInstance.close();
        mnHelper.reloadState();
      });
    };
  });
