angular.module('mnBuckets').controller('mnBucketsFlushDialogController',
  function ($scope, $modalInstance, bucket, mnPromiseHelper, mnBucketsDetailsService) {
    $scope.doFlush = function () {
      var promise = mnBucketsDetailsService.flushBucket(bucket);
      mnPromiseHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
