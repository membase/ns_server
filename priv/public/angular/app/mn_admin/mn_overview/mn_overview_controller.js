angular.module('mnOverview').controller('mnOverviewController',
  function ($scope, $interval, nodes, buckets, mnOverviewService) {
    function scopeApplyer(method) {
      return function callee() {
        method().then(_.partial(_.extend, $scope));
        return callee;
      };
    }
    var getStatsId = $interval(scopeApplyer(mnOverviewService.getStats)(), 3000);
    var overviewId = $interval(scopeApplyer(mnOverviewService.getOverviewConfig)(), 3000);

    $scope.bucketsLength = buckets.data.length;
    $scope.failedOver = nodes.failedOver;
    $scope.down = nodes.down;
    $scope.pending = nodes.pending;
    $scope.active = nodes.active;

    $scope.$on('$destroy', function () {
      $interval.cancel(getStatsId);
      $interval.cancel(overviewId);
    });
  });