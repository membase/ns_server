angular.module('mnServers').controller('mnServersStopRebalanceDialogController',
  function ($scope, $uibModalInstance, mnPromiseHelper, mnServersService) {
    $scope.onStopRebalance = function () {
      mnPromiseHelper.handleModalAction($scope, mnServersService.stopRebalance(), $uibModalInstance);
    };
  });
