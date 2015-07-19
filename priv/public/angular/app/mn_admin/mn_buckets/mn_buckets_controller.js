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
  function ($scope, buckets, mnBucketsService, mnHelper, mnPoll, $modal) {
    function applyBuckets(buckets) {
      $scope.buckets = buckets;
    }
    applyBuckets(buckets);

    $scope.addBucket = function () {
      mnBucketsService.getBucketsState().then(function (buckets) {
        applyBuckets(buckets);

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

    mnPoll.start($scope, function () {
      return mnBucketsService.getBucketsState();
    }).subscribe(applyBuckets);
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });