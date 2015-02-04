angular.module('mnServers').controller('mnServersStopRebalanceDialogController',
  function ($scope, $modalInstance, mnHelper, mnServersService) {
    $scope.onStopRebalance = function () {
      mnHelper.handleModalAction($scope, mnServersService.stopRebalance(), $modalInstance);
    };
  });
