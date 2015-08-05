angular.module('mnAnalytics', [
  'mnHelper',
  'mnHttp',
  'mnAnalyticsService',
  'ui.router',
  'mnPoll'
]).controller('mnAnalyticsController',
  function ($scope, mnAnalyticsService, mnHelper, $state, mnHttp, mnPoll) {

    mnPoll.start($scope, function (previousResult) {
      return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
    }, function (response) {
      //TODO add error handler
      return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
    }).subscribe("state").keepIn();

    $scope.$watch('state.bucketsNames.selected', function (selectedBucket) {
      selectedBucket && selectedBucket !== $state.params.analyticsBucket && $state.go('app.admin.analytics.list.graph', {
        analyticsBucket: selectedBucket
      });
    });

    if (!$state.params.specificStat) {
      $scope.$watch('state.nodesNames.selected', function (selectedHostname) {
        selectedHostname && selectedHostname !== $state.params.statsHostname && $state.go('app.admin.analytics.list.graph', {
          statsHostname: selectedHostname.indexOf("All Server Nodes") > -1 ? undefined : selectedHostname
        });
      });
    }

    $scope.computeOps = function (key) {
      return Math.round(key.ops * 100.0) / 100.0;
    };

    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });