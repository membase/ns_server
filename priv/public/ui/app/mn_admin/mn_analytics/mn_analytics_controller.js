(function () {
  "use strict";

  angular
    .module('mnAnalytics', [
      'mnHelper',
      'mnAnalyticsService',
      'ui.router',
      'mnPoll'
    ])
    .controller('mnAnalyticsController', mnAnalyticsController);

  function mnAnalyticsController($scope, mnAnalyticsService, mnHelper, $state, $http, mnPoller) {
    var vm = this;

    vm.computeOps = computeOps;
    vm.onSelectBucket = onSelectBucket;
    vm.onSelectNode = onSelectNode;

    activate();

    function activate() {
      var poller = new mnPoller($scope, function (previousResult) {
        return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
      })
      .setExtractInterval(function (response) {
        //TODO add error handler
        return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
      })
      .subscribe("state", vm)
      .reloadOnScopeEvent("reloadAnalyticsPoller", vm);
    }
    function onSelectBucket(selectedBucket) {
      $state.go('app.admin.analytics.list.graph', {
        analyticsBucket: selectedBucket
      });
    }
    function onSelectNode(selectedHostname) {
      $state.go('app.admin.analytics.list.graph', {
        statsHostname: selectedHostname.indexOf("All Server Nodes") > -1 ? undefined : selectedHostname
      });
    }
    function computeOps(key) {
      return Math.round(key.ops * 100.0) / 100.0;
    }
  }
})();
