angular.module('mnXDCR').controller('mnXDCRReferenceDialogController',
  function ($scope, $modalInstance, mnPromiseHelper, mnXDCRService, reference) {
    $scope.cluster = reference ? _.clone(reference) : {username: 'Administrator'};
    $scope.createClusterReference = function () {
      var promise = mnXDCRService.saveClusterReference($scope.cluster, reference && reference.name);
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .cancelOnScopeDestroy()
        .closeOnSuccess()
        .reloadState();
    };
  });
