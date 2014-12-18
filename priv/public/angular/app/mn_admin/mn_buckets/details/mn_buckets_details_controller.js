angular.module('mnBuckets').controller('mnBucketsDetailsController',
  function ($scope, mnBucketsDetailsService, mnCompaction, mnHelper, $modal, mnBytesToMBFilter, mnBucketsDetailsDialogService) {
    function getBucketsDetaisl() {
      mnBucketsDetailsService.getDetails($scope.bucket).then(function (details) {
        $scope.bucketDetails = details;
      });
    }
    $scope.editBucket = function () {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
        controller: 'mnBucketsDetailsDialogController',
        resolve: {
          bucketConf: function () {
            return mnBucketsDetailsDialogService.reviewBucketConf($scope.bucketDetails);
          }
        }
      });
    };
    $scope.deleteBucket = function (bucket) {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_buckets/delete_dialog/mn_buckets_delete_dialog.html',
        controller: 'mnBucketsDeleteDialogController',
        resolve: {
          bucket: function () {
            return bucket;
          }
        }
      });
    };
    $scope.flushBucket = function (bucket) {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_buckets/flush_dialog/mn_buckets_flush_dialog.html',
        controller: 'mnBucketsFlushDialogController',
        resolve: {
          bucket: function () {
            return bucket;
          }
        }
      });
    };

    $scope.registerCompactionAsTriggeredAndPost = function (url) {
      mnCompaction.registerAsTriggeredAndPost(url).then(getBucketsDetaisl);
    };
    $scope.$watch('bucket', getBucketsDetaisl);
  });