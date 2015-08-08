angular.module('mnServers').controller('mnServersFailOverDialogController',
  function ($scope, mnServersService, mnPromiseHelper, node, $modalInstance) {
    $scope.node = node;

    var promise = mnServersService.getNodeStatuses(node.hostname);
    mnPromiseHelper($scope, promise)
      .showSpinner()
      .getPromise()
      .then(function (details) {
        if (details) {
          $scope.status = details;
        } else {
          $modalInstance.close();
        }
      });

    $scope.onSubmit = function () {
      var promise = mnServersService.postFailover($scope.status.failOver, node.otpNode);
      mnPromiseHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
