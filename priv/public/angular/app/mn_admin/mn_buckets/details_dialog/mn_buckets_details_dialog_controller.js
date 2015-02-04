angular.module('mnBuckets').controller('mnBucketsDetailsDialogController',
  function ($scope, $state, mnBucketsDetailsDialogService, bucketConf, mnHelper, $modalInstance) {
    $scope.bucketConf = bucketConf;

    $scope.onSubmit = function () {
      var promise = mnBucketsDetailsDialogService.postBuckets($scope.bucketConf);
      mnHelper
        .promiseHelper($scope, promise)
        .showErrorsSensitiveSpinner()
        .getPromise()
        .then(function (result) {
          if (!result.data) {
            $modalInstance.close();
            mnHelper.reloadState();
          }
        });
    };
  });