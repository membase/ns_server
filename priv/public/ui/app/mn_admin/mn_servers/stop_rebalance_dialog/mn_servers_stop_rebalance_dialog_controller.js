angular.module('mnServers').controller('mnServersStopRebalanceDialogController',
  function ($scope, $modalInstance, mnPromiseHelper, mnServersService) {
    $scope.onStopRebalance = function () {
      mnPromiseHelper.handleModalAction($scope, mnServersService.stopRebalance(), $modalInstance);
    };
  });
