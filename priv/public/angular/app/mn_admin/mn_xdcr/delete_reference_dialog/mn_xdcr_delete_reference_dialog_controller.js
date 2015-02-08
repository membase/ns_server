angular.module('mnXDCR').controller('mnXDCRDeleteReferenceDialogController',
  function ($scope, $modalInstance, mnHelper, mnXDCRService, name) {
    $scope.name = name;
    $scope.deleteClusterReference = function () {
      var promise = mnXDCRService.deleteClusterReference(name);
      mnHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
