angular.module('mnBuckets').directive('mnBucketsList', function (mnHelper) {
  return {
    restrict: 'A',
    scope: {
      buckets: '='
    },
    isolate: false,
    templateUrl: 'mn_admin/mn_buckets/list/mn_buckets_list.html',
    controller: function ($scope) {
      mnHelper.initializeDetailsHashObserver($scope, 'openedBucket', 'app.admin.buckets');
    }
  };
});