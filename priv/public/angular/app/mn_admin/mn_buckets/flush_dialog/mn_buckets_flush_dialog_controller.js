angular.module('mnBuckets').controller('mnBucketsFlushDialogController',
  function ($scope, $modalInstance, bucket, mnHelper, mnBucketsDetailsService) {
    $scope.doFlush = function () {
      var promise = mnBucketsDetailsService.flushBucket(bucket);
      mnHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
