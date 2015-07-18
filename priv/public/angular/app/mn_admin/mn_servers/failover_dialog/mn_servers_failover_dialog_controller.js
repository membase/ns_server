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

      $scope.$watch('failOver', function (failOver) {console.log(failOver)})

    $scope.onSubmit = function () {
      var promise = mnServersService.postFailover($scope.failOver, node.otpNode);
      mnPromiseHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
