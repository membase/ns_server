angular.module('mnBuckets').controller('mnBucketsDetailsDialogController',
  function ($scope, $state, mnBucketsDetailsDialogService, bucketConf, mnHelper, $modalInstance) {
    $scope.bucketConf = bucketConf;

    $scope.onSubmit = function () {
      var promise = mnBucketsDetailsDialogService.postBuckets($scope.bucketConf);
      mnHelper.handleSpinner($scope, promise, null, true);
      promise.then(function (result) {
        if (!result.data) {
          $modalInstance.dismiss('cancel');
          mnHelper.reloadState();
        } else {
          $scope.validationResult = result;
        }
      });
    };

    $scope.cancel = function () {
      $modalInstance.dismiss('cancel');
    };
  });