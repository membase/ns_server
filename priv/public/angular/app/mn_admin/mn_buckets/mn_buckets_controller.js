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
]).controller('mnBucketsController',
  function ($scope, mnBucketsService, mnHelper, mnPoolDefault, mnPromiseHelper, mnPoll, $modal) {
    var poolDefault = mnPoolDefault.latestValue();
    $scope.isCreateNewDataBucketDisabled = function () {
      return !$scope.mnBucketsState || poolDefault.value.isROAdminCreds || $scope.areThereCreationWarnings();
    };
    $scope.isBucketCreationWarning = function () {
      return poolDefault.value.rebalancing;
    };
    $scope.isBucketFullyAllocatedWarning = function () {
      return poolDefault.value.storageTotals.ram.quotaTotal === poolDefault.value.storageTotals.ram.quotaUsed;
    };
    $scope.isMaxBucketCountWarning = function () {
      return ($scope.mnBucketsState || []).length >= poolDefault.value.maxBucketCount;
    };
    $scope.areThereCreationWarnings = function () {
      return $scope.isMaxBucketCountWarning() || $scope.isBucketFullyAllocatedWarning() || $scope.isBucketCreationWarning();
    };
    $scope.maxBucketCount = poolDefault.value.maxBucketCount;
    $scope.addBucket = function () {
      mnPromiseHelper($scope, mnBucketsService.getBucketsState())
        .applyToScope("mnBucketsState")
        .cancelOnScopeDestroy()
        .onSuccess(function (mnBucketsState) {
          !$scope.areThereCreationWarnings() && $modal.open({
            templateUrl: 'mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
            controller: 'mnBucketsDetailsDialogController',
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
    };

    mnPoll
      .start($scope, mnBucketsService.getBucketsState)
      .subscribe("mnBucketsState")
      .keepIn("app.admin.buckets")
      .cancelOnScopeDestroy()
      .run();

  });