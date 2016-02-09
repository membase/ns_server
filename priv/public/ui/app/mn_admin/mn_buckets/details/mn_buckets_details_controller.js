(function () {
  "use strict";

  angular
    .module('mnBuckets')
    .controller('mnBucketsDetailsController', mnBucketsDetailsController);

    function mnBucketsDetailsController($scope, mnBucketsDetailsService, mnTasksDetails, mnPromiseHelper, mnSettingsAutoCompactionService, mnCompaction, mnHelper, $uibModal, mnBytesToMBFilter, mnBucketsDetailsDialogService) {
      var vm = this;
      vm.editBucket = editBucket;
      vm.deleteBucket = deleteBucket;
      vm.flushBucket = flushBucket;
      vm.registerCompactionAsTriggeredAndPost = registerCompactionAsTriggeredAndPost;
      vm.getBucketRamGuageConfig = getBucketRamGuageConfig;
      vm.getGuageConfig = getGuageConfig;

      activate();

      function activate() {
        $scope.$watch('bucket', getBucketsDetails);
      }
      function getBucketsDetails() {
        mnPromiseHelper(vm, mnBucketsDetailsService.getWarmUpTasks($scope.bucket))
          .applyToScope("warmUpTasks");
        mnPromiseHelper(vm, mnBucketsDetailsService.doGetDetails($scope.bucket))
          .applyToScope("bucketDetails");
        mnPromiseHelper(vm, mnBucketsDetailsService.getCompactionTask($scope.bucket))
          .applyToScope("compactionTasks");
      }
      function getBucketRamGuageConfig(details) {
        return mnBucketsDetailsService.getBucketRamGuageConfig(details && {
          total: details.basicStats.storageTotals.ram.quotaTotalPerNode * details.nodes.length,
          thisAlloc: details.quota.ram,
          otherBuckets: details.basicStats.storageTotals.ram.quotaUsedPerNode * details.nodes.length - details.quota.ram
        });
      }
      function getGuageConfig(details) {
        if (!details) {
          return;
        }
        return mnBucketsDetailsService.getGuageConfig(
          details.basicStats.storageTotals.hdd.total,
          details.basicStats.diskUsed,
          details.basicStats.storageTotals.hdd.usedByData - details.basicStats.diskUsed,
          details.basicStats.storageTotals.hdd.used - details.basicStats.storageTotals.hdd.usedByData
        );
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
                      mnSettingsAutoCompactionService.getAutoCompaction(true) :
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
        vm.compactionTasks[disableButtonKey] = true;
        mnPromiseHelper(vm, mnCompaction.registerAsTriggeredAndPost(url))
          .onSuccess(getBucketsDetails);
      };
    }
})();
