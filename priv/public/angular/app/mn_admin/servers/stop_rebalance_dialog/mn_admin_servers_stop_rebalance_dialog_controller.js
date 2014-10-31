angular.module('mnAdminServers').controller('mnAdminServersStopRebalanceController',
  function ($scope, $modalInstance, mnHelper, $state, mnAdminServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    }
    $scope.onStopRebalance = function () {
      var request = mnAdminServersService.stopRebalance();
      request.then(function () {
        $modalInstance.close();
      });
      mnHelper.handleSpinner($scope, 'mnDialogStopRebalanceDialogLoading', request);
    };
  });
