angular.module('mnBuckets', [
  'mnHelper',
  'mnBucketsService',
  'ui.bootstrap',
  'mnBucketsDetailsDialogService',
  'mnBarUsage',
  'mnBucketsForm',
  'mnPromiseHelper',
  'mnPoll'
]).controller('mnBucketsController',
  function ($scope, mnBucketsService, mnHelper, mnPoll, $modal) {

    $scope.addBucket = function () {
      mnBucketsService.getBucketsState().then(function (buckets) {
        $scope.buckets = buckets;

        !buckets.creationWarnings.length && $modal.open({
          templateUrl: '/angular/app/mn_admin/mn_buckets/details_dialog/mn_buckets_details_dialog.html',
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

    mnPoll.start($scope, mnBucketsService.getBucketsState).subscribe("buckets");

    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });