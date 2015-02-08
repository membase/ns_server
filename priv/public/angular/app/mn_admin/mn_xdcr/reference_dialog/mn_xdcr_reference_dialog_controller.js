angular.module('mnXDCR').controller('mnXDCRReferenceDialogController',
  function ($scope, $modalInstance, mnHelper, mnXDCRService, reference) {
    $scope.cluster = reference ? _.clone(reference) : {username: 'Administrator'};
    $scope.createClusterReference = function () {
      var promise = mnXDCRService.saveClusterReference($scope.cluster, reference && reference.name);
      mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
