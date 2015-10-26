angular.module('mnBuckets').controller('mnBucketsDetailsController',
  function ($scope, mnBucketsDetailsService, mnPoolDefault, mnPromiseHelper, mnSettingsAutoCompactionService, mnCompaction, mnHelper, $modal, mnBytesToMBFilter, mnBucketsDetailsDialogService) {
    function getBucketsDetails() {
      mnPromiseHelper($scope, mnBucketsDetailsService.getDetails($scope.bucket))
        .applyToScope("bucketDetails")
        .cancelOnScopeDestroy();
    }
    $scope.mnPoolDefault = mnPoolDefault.latestValue();
    $scope.editBucket = function () {
      $modal.open({
        templateUrl: 'app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
        controller: 'mnBucketsDetailsDialogController',
        resolve: {
          bucketConf: function () {
            return mnBucketsDetailsDialogService.reviewBucketConf($scope.bucketDetails);
          },
          autoCompactionSettings: function () {
            return !$scope.bucketDetails.autoCompactionSettings ?
                    mnSettingsAutoCompactionService.getAutoCompaction() :
                    mnSettingsAutoCompactionService.prepareSettingsForView($scope.bucketDetails);
          }
        }
      });
    };
    $scope.deleteBucket = function (bucket) {
      $modal.open({
        templateUrl: 'app/mn_admin/mn_buckets/delete_dialog/mn_buckets_delete_dialog.html',
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
        templateUrl: 'app/mn_admin/mn_buckets/flush_dialog/mn_buckets_flush_dialog.html',
        controller: 'mnBucketsFlushDialogController',
        resolve: {
          bucket: function () {
            return bucket;
          }
        }
      });
    };

    $scope.registerCompactionAsTriggeredAndPost = function (url, disableButtonKey) {
      $scope.bucketDetails[disableButtonKey] = true;
      mnPromiseHelper($scope, mnCompaction.registerAsTriggeredAndPost(url))
        .onSuccess(getBucketsDetails)
        .cancelOnScopeDestroy();
    };
    $scope.$watch('bucket', getBucketsDetails);
  });