angular.module('mnServers').controller('mnServersEjectDialogController',
  function ($scope, $uibModalInstance, node, warnings, mnHelper, mnPromiseHelper, mnServersService) {
    $scope.cancel = function () {
      $uibModalInstance.dismiss('cancel');
    };
    $scope.warningFlags = warnings;
    $scope.doEjectServer = function () {
      mnServersService.addToPendingEject(node);
      $uibModalInstance.close();
      mnHelper.reloadState();
    };
  });
