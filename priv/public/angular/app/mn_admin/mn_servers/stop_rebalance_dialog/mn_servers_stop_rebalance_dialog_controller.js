angular.module('mnServers').controller('mnServersStopRebalanceController',
  function ($scope, $modalInstance, mnHelper, $state, mnServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    }
    $scope.onStopRebalance = function () {
      var request = mnServersService.stopRebalance();
      request.then(function () {
        $modalInstance.close();
      });
      mnHelper.handleSpinner($scope, 'mnDialogStopRebalanceDialogLoading', request);
    };
  });
