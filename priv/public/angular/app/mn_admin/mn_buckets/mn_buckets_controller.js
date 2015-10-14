angular.module('mnBuckets', [
  'mnHelper',
  'mnBucketsService',
  'ui.bootstrap',
  'mnBucketsDetailsDialogService',
  'mnBarUsage',
  'mnBucketsForm',
  'mnPromiseHelper',
  'mnPoll',
  'mnPoolDefault'
]).controller('mnBucketsController',
  function ($scope, mnBucketsService, mnHelper, poolDefault, mnPromiseHelper, mnPoll, $modal) {
    $scope.isCreateNewDataBucketDisabled = function () {
      return !$scope.mnBucketsState || poolDefault.isROAdminCreds || !!$scope.mnBucketsState.creationWarnings.length;
    };
    $scope.addBucket = function () {
      mnPromiseHelper($scope, mnBucketsService.getBucketsState())
        .applyToScope("mnBucketsState")
        .cancelOnScopeDestroy()
        .onSuccess(function (mnBucketsState) {
          !mnBucketsState.creationWarnings.length && $modal.open({
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
      .keepIn()
      .cancelOnScopeDestroy()
      .run();

  });