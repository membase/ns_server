angular.module('mnXDCR').controller('mnXDCRDeleteDialogController',
  function ($scope, $uibModalInstance, mnPromiseHelper, mnXDCRService, id) {
    $scope.deleteReplication = function () {
      var promise = mnXDCRService.deleteReplication(id);
      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance);
    };
  });
