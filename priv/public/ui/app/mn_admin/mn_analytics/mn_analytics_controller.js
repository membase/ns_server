(function () {
  "use strict";

  angular
    .module('mnAnalytics', [
      'mnHelper',
      'mnAnalyticsService',
      'ui.router',
      'mnPoll',
      'mnBucketsService'
    ])
    .controller('mnAnalyticsController', mnAnalyticsController);

  function mnAnalyticsController($scope, mnAnalyticsService, mnHelper, $state, $http, mnPoller, mnBucketsService) {
    var vm = this;

    vm.computeOps = computeOps;
    vm.onSelectBucket = onSelectBucket;
    vm.onSelectNode = onSelectNode;

    activate();


    vm.isSpecificStats = !!$state.params.specificStat

    function activate() {
      if (!$state.params.specificStat) {
        new mnPoller($scope, function (previousResult) {
          return mnAnalyticsService.prepareNodesList($state.params);
        })
        .setExtractInterval(10000)
        .subscribe("nodes", vm)
        // .reloadOnScopeEvent("reloadAnalyticsPoller", vm)
        .cycle();
      }

      //TODO separate dictionary from _uistats
      new mnPoller($scope, function (previousResult) {
        return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
      })
      .setExtractInterval(function (response) {
        //TODO add error handler
        return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
      })
      .subscribe("state", vm)
      .reloadOnScopeEvent("reloadAnalyticsPoller", vm);

      new mnPoller($scope, function (previousResult) {
        return mnBucketsService.getBucketsByType().then(function (buckets) {
          var rv = {};
          rv.bucketsNames = buckets.byType.names;
          rv.bucketsNames.selected = $state.params.analyticsBucket;
          return rv;
        });
      })
      .setExtractInterval(10000)
      .subscribe("buckets", vm)
      // .reloadOnScopeEvent("reloadAnalyticsPoller", vm)
      .cycle();
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
