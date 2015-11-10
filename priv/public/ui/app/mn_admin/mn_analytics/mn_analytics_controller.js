angular.module('mnAnalytics', [
  'mnHelper',
  'mnHttp',
  'mnAnalyticsService',
  'ui.router',
  'mnPoll'
]).controller('mnAnalyticsController',
  function ($scope, mnAnalyticsService, mnHelper, $state, mnHttp, mnPoller) {

    new mnPoller($scope, function (previousResult) {
        return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
      })
      .setExtractInterval(function (response) {
        //TODO add error handler
        return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
      })
      .subscribe("mnAnalyticsState")
      .keepIn("app.admin.analytics")
      .cancelOnScopeDestroy()
      .cycle();

    $scope.$watch('mnAnalyticsState.bucketsNames.selected', function (selectedBucket) {
      selectedBucket && selectedBucket !== $state.params.analyticsBucket && $state.go('app.admin.analytics.list.graph', {
        analyticsBucket: selectedBucket
      }, {
        location: !$state.params.viewsBucket ? "replace" : true
      });
    });

    if (!$state.params.specificStat) {
      $scope.$watch('mnAnalyticsState.nodesNames.selected', function (selectedHostname) {
        selectedHostname && selectedHostname !== $state.params.statsHostname && $state.go('app.admin.analytics.list.graph', {
          statsHostname: selectedHostname.indexOf("All Server Nodes") > -1 ? undefined : selectedHostname
        });
      });
    }

    $scope.computeOps = function (key) {
      return Math.round(key.ops * 100.0) / 100.0;
    };

  });