angular.module('mnServers').controller('mnServersFailOverDialogController',
  function ($scope, mnServersService, mnPromiseHelper, node, $uibModalInstance) {
    $scope.node = node;

    var promise = mnServersService.getNodeStatuses(node.hostname);
    mnPromiseHelper($scope, promise)
      .showSpinner()
      .cancelOnScopeDestroy()
      .getPromise()
      .then(function (details) {
        if (details) {
          $scope.status = details;
        } else {
          $uibModalInstance.close();
        }
      });

    $scope.onSubmit = function () {
      var promise = mnServersService.postFailover($scope.status.failOver, node.otpNode);
      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance);
    };
  });
