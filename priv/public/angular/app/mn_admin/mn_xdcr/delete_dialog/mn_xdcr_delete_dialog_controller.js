angular.module('mnXDCR').controller('mnXDCRDeleteDialogController',
  function ($scope, $modalInstance, mnHelper, mnXDCRService, id) {
    $scope.deleteReplication = function () {
      var promise = mnXDCRService.deleteReplication(id);
      mnHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
