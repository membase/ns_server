angular.module('mnBuckets').controller('mnBucketsController',
  function ($scope, buckets, mnBucketsService, mnHelper) {
    function applyBuckets(buckets) {
      $scope.buckets = buckets;
    }
    applyBuckets(buckets);

    mnHelper.setupLongPolling({
      methodToCall: mnBucketsService.getBuckets,
      scope: $scope,
      onUpdate: applyBuckets
    });
  });