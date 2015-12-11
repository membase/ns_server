(function () {
  "use strict";

  angular
    .module('mnBuckets')
    .controller('mnBucketsDetailsController', mnBucketsDetailsController);

    function mnBucketsDetailsController($scope, mnBucketsDetailsService, mnPoolDefault, mnPromiseHelper, mnSettingsAutoCompactionService, mnCompaction, mnHelper, $uibModal, mnBytesToMBFilter, mnBucketsDetailsDialogService) {
      var vm = this;
      vm.mnPoolDefault = mnPoolDefault.latestValue();
      vm.editBucket = editBucket;
      vm.deleteBucket = deleteBucket;
      vm.flushBucket = flushBucket;
      vm.registerCompactionAsTriggeredAndPost = registerCompactionAsTriggeredAndPost;

      activate();

      function activate() {
        $scope.$watch('bucket', getBucketsDetails);
      }
      function getBucketsDetails() {
        mnPromiseHelper(vm, mnBucketsDetailsService.getDetails($scope.bucket))
          .applyToScope("bucketDetails");
      }
      function editBucket() {
        $uibModal.open({
          templateUrl: 'app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
          controller: 'mnBucketsDetailsDialogController as bucketsDetailsDialogCtl',
          resolve: {
            bucketConf: function () {
              return mnBucketsDetailsDialogService.reviewBucketConf(vm.bucketDetails);
            },
            autoCompactionSettings: function () {
              return !vm.bucketDetails.autoCompactionSettings ?
                      mnSettingsAutoCompactionService.getAutoCompaction() :
                      mnSettingsAutoCompactionService.prepareSettingsForView(vm.bucketDetails);
            }
          }
        });
      }
      function deleteBucket(bucket) {
        $uibModal.open({
          templateUrl: 'app/mn_admin/mn_buckets/delete_dialog/mn_buckets_delete_dialog.html',
          controller: 'mnBucketsDeleteDialogController as bucketsDeleteDialogCtl',
          resolve: {
            bucket: function () {
              return bucket;
            }
          }
        });
      }
      function flushBucket(bucket) {
        $uibModal.open({
          templateUrl: 'app/mn_admin/mn_buckets/flush_dialog/mn_buckets_flush_dialog.html',
          controller: 'mnBucketsFlushDialogController as bucketsFlushDialogCtl',
          resolve: {
            bucket: function () {
              return bucket;
            }
          }
        });
      }
      function registerCompactionAsTriggeredAndPost(url, disableButtonKey) {
        vm.bucketDetails[disableButtonKey] = true;
        mnPromiseHelper(vm, mnCompaction.registerAsTriggeredAndPost(url))
          .onSuccess(getBucketsDetails);
      };
    }
})();
