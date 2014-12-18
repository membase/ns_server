angular.module('mnBuckets').controller('mnBucketsFlushDialogController',
  function ($scope, $modalInstance, bucket, mnHelper, mnBucketsDetailsService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.doFlush = function () {
      var promise = mnBucketsDetailsService.flushBucket(bucket);
      mnHelper.handleSpinner($scope, promise, null, true);
      promise['finally'](function () {
        mnHelper.reloadState();
        $modalInstance.close();
      });
    };
  });
