angular.module('mnBuckets').controller('mnBucketsController',
  function ($scope, buckets, mnBucketsService, mnHelper, $modal) {
    function applyBuckets(buckets) {
      $scope.buckets = buckets;
    }
    applyBuckets(buckets);

    $scope.addBucket = function () {
      mnBucketsService.getBuckets().then(function (buckets) {
        applyBuckets(buckets);

        !buckets.creationWarnings.length && $modal.open({
          templateUrl: '/angular/app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
          controller: 'mnBucketsDetailsDialogController',
          resolve: {
            bucketConf: function (mnBucketsDetailsDialogService) {
              return mnBucketsDetailsDialogService.getNewBucketConf();
            }
          }
        });
      });
    };

    mnHelper.setupLongPolling({
      methodToCall: mnBucketsService.getBuckets,
      scope: $scope,
      onUpdate: applyBuckets
    });
  });