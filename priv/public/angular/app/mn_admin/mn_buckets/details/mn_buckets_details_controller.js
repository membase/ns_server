angular.module('mnBuckets').controller('mnBucketsDetailsController',
  function ($scope, mnBucketsDetailsService, mnCompaction, mnHelper) {
    function getBucketsDetaisl() {
      mnBucketsDetailsService.getDetails($scope.bucket).then(function (details) {
        $scope.bucketDetails = details;
      });
    }
    $scope.$watch('bucket', getBucketsDetaisl);

    $scope.registerCompactionAsTriggeredAndPost = function (url) {
      mnCompaction.registerAsTriggeredAndPost(url).then(getBucketsDetaisl);
    };
  });