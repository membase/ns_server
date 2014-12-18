angular.module('mnBuckets').controller('mnBucketsDeleteDialogController',
  function ($scope, $modalInstance, bucket, mnHelper, mnBucketsDetailsService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.doDelete = function () {
      var promise = mnBucketsDetailsService.deleteBucket(bucket);
      mnHelper.handleSpinner($scope, promise, null, true);
      promise['finally'](function () {
        mnHelper.reloadState();
        $modalInstance.close();
      });
    };
  });
