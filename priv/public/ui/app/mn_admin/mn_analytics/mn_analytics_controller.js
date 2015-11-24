(function () {
  "use strict";

  angular
    .module('mnAnalytics', [
      'mnHelper',
      'mnHttp',
      'mnAnalyticsService',
      'ui.router',
      'mnPoll'
    ])
    .controller('mnAnalyticsController', mnAnalyticsController);

  function mnAnalyticsController($scope, mnAnalyticsService, mnHelper, $state, mnHttp, mnPoller) {
    var vm = this;

    vm.computeOps = computeOps;

    activate();

    function activate() {
      new mnPoller($scope, function (previousResult) {
        return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
      })
      .setExtractInterval(function (response) {
        //TODO add error handler
        return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
      })
      .subscribe("mnAnalyticsState", vm)
      .keepIn("app.admin.analytics", vm)
      .cancelOnScopeDestroy()
      .cycle();

      $scope.$watch('mnAnalyticsController.mnAnalyticsState.bucketsNames.selected', watchOnSelectedBucket);
      if (!$state.params.specificStat) {
        $scope.$watch('mnAnalyticsController.mnAnalyticsState.nodesNames.selected', watchOnSelectedNode);
      }
    }
    function watchOnSelectedBucket(selectedBucket) {
      selectedBucket && selectedBucket !== $state.params.analyticsBucket && $state.go('app.admin.analytics.list.graph', {
        analyticsBucket: selectedBucket
      }, {
        location: !$state.params.viewsBucket ? "replace" : true
      });
    }
    function watchOnSelectedNode(selectedHostname) {
      selectedHostname && selectedHostname !== $state.params.statsHostname && $state.go('app.admin.analytics.list.graph', {
        statsHostname: selectedHostname.indexOf("All Server Nodes") > -1 ? undefined : selectedHostname
      });
    }
    function computeOps(key) {
      return Math.round(key.ops * 100.0) / 100.0;
    }
  }
})();
