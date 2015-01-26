angular.module('mnBuckets').controller('mnBucketsDeleteDialogController',
  function ($scope, $modalInstance, bucket, mnHelper, mnBucketsDetailsService, mnAlertsService) {
    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
    $scope.doDelete = function () {
      var promise = mnBucketsDetailsService.deleteBucket(bucket).then(null, function (resp) {
        mnAlertsService.formatAndSetAlerts(resp.data, 'danger');
      });
      mnHelper.handleSpinner($scope, promise, null, true);
      promise['finally'](function () {
        mnHelper.reloadState();
        $modalInstance.close();
      });
    };
  });
