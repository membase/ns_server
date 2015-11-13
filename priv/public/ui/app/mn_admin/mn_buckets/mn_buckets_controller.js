(function () {
  angular.module('mnBuckets', [
    'mnHelper',
    'mnBucketsService',
    'ui.bootstrap',
    'mnBucketsDetailsDialogService',
    'mnBarUsage',
    'mnBucketsForm',
    'mnPromiseHelper',
    'mnPoll',
    'mnPoolDefault',
    'mnSpinner'
  ]).controller('mnBucketsController', mnBucketsController);

  function mnBucketsController($scope, mnBucketsService, mnHelper, mnPoolDefault, mnPromiseHelper, mnPoller, $uibModal) {
    var vm = this;

    var poolDefault = mnPoolDefault.latestValue();

    vm.isCreateNewDataBucketDisabled = isCreateNewDataBucketDisabled;
    vm.isBucketCreationWarning = isBucketCreationWarning;
    vm.isBucketFullyAllocatedWarning = isBucketFullyAllocatedWarning;
    vm.isMaxBucketCountWarning = isMaxBucketCountWarning;
    vm.areThereCreationWarnings = areThereCreationWarnings;
    vm.addBucket = addBucket;

    vm.maxBucketCount = poolDefault.value.maxBucketCount;

    activate();

    function isCreateNewDataBucketDisabled() {
      return !vm.mnBucketsState || poolDefault.value.isROAdminCreds || areThereCreationWarnings();
    }
    function isBucketCreationWarning() {
      return poolDefault.value.rebalancing;
    }
    function isBucketFullyAllocatedWarning() {
      return poolDefault.value.storageTotals.ram.quotaTotal === poolDefault.value.storageTotals.ram.quotaUsed;
    }
    function isMaxBucketCountWarning() {
      return (vm.mnBucketsState || []).length >= poolDefault.value.maxBucketCount;
    }
    function areThereCreationWarnings() {
      return isMaxBucketCountWarning() || isBucketFullyAllocatedWarning() || isBucketCreationWarning();
    }
    function addBucket() {
      mnPromiseHelper(vm, mnBucketsService.getBucketsState())
        .applyToScope("mnBucketsState")
        .cancelOnScopeDestroy($scope)
        .onSuccess(function (mnBucketsState) {
          !areThereCreationWarnings() && $uibModal.open({
            templateUrl: 'app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
            controller: 'mnBucketsDetailsDialogController as mnBucketsDetailsDialogController',
            resolve: {
              bucketConf: function (mnBucketsDetailsDialogService) {
                return mnBucketsDetailsDialogService.getNewBucketConf();
              },
              autoCompactionSettings: function (mnSettingsAutoCompactionService) {
                return mnSettingsAutoCompactionService.getAutoCompaction();
              }
            }
          });
        });
    }
    function activate() {
      new mnPoller($scope, mnBucketsService.getBucketsState)
      .subscribe("mnBucketsState", vm)
      .keepIn("app.admin.buckets", vm)
      .cancelOnScopeDestroy()
      .cycle();
    }
  }
})();
