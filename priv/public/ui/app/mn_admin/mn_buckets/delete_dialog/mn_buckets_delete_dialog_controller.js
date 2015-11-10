angular.module('mnBuckets').controller('mnBucketsDeleteDialogController',
  function ($scope, $uibModalInstance, bucket, mnHelper, mnPromiseHelper, mnBucketsDetailsService, mnAlertsService) {
    $scope.doDelete = function () {
      var promise = mnBucketsDetailsService.deleteBucket(bucket);
      mnPromiseHelper($scope, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors()
        .closeFinally()
        .reloadState();
    };
  });
