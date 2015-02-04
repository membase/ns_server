angular.module('mnBuckets').controller('mnBucketsDeleteDialogController',
  function ($scope, $modalInstance, bucket, mnHelper, mnBucketsDetailsService, mnAlertsService) {
    $scope.doDelete = function () {
      var promise = mnBucketsDetailsService.deleteBucket(bucket);
      mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors()
        .closeFinally()
        .reloadState();
    };
  });
