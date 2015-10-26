angular.module('mnBuckets').directive('mnBucketsList', function (mnHelper, mnPoolDefault) {
  return {
    restrict: 'A',
    scope: {
      buckets: '='
    },
    isolate: false,
    templateUrl: 'app/mn_admin/mn_buckets/list/mn_buckets_list.html',
    controller: function ($scope) {
      $scope.mnPoolDefault = mnPoolDefault.latestValue();
      mnHelper.initializeDetailsHashObserver($scope, 'openedBucket', 'app.admin.buckets');
    }
  };
});