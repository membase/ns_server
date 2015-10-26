angular.module('mnBuckets').controller('mnBucketsDeleteDialogController',
  function ($scope, $modalInstance, bucket, mnHelper, mnPromiseHelper, mnBucketsDetailsService, mnAlertsService) {
    $scope.doDelete = function () {
      var promise = mnBucketsDetailsService.deleteBucket(bucket);
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors()
        .closeFinally()
        .cleanPollCache("mnBucketsState")
        .reloadState();
    };
  });
