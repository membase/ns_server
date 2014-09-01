angular.module('mnAdminServers').controller('mnAdminServersFailOverDialogController',
  function ($scope, mnAdminService, mnAdminServersService, mnAdminServersFailOverDialogService, mnDialogService) {

    var failoverDialog = mnAdminServersFailOverDialogService;

    $scope.failoverDialogModel = failoverDialog.model;

    $scope.confirmation = false;

    $scope.viewLoading = true;

    $scope.$on('$destroy', function () {
      $scope.failoverDialogModel.nodeStatuses = undefined;
    });

    failoverDialog.getNodeStatuses(mnAdminService.model.details.nodeStatusesUri)
      .success(function (nodeStatuses) {
        if (!nodeStatuses) {
          return;
        }

        $scope.failoverDialogModel.nodeStatuses = nodeStatuses;
        $scope.viewLoading = false;

        var node = nodeStatuses[$scope.node.hostname];
        if (!node) {
          mnDialogService.removeLastOpened();
        }
        $scope.down = node.status != 'healthy';
        $scope.backfill = node.replication < 1;
        $scope.failOver = node.gracefulFailoverPossible ? "startGracefulFailover" : "failOver";
        $scope.gracefulFailoverPossible = node.gracefulFailoverPossible;
        $scope.down && ($scope.failOver = 'failOver');
        !$scope.backfill && ($scope.confirmation = true);
      });

    $scope.onSubmit = function () {
      var url = mnAdminService.model.details.controllers[$scope.failOver].uri;
      mnAdminServersService.postAndReload(url, {otpNode: $scope.node.otpNode}, {timeout: 120000}).success(mnDialogService.removeLastOpened);
    };
  });
