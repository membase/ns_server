angular.module('mnServers').controller('mnServersEjectDialogController',
  function ($scope, $modalInstance, node, warnings, mnHelper, mnPromiseHelper, mnServersService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.warningFlags = warnings;
    $scope.doEjectServer = function () {
      mnServersService.addToPendingEject(node);
      $modalInstance.close();
      mnHelper.reloadState();
    };
  });
