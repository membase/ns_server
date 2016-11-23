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

  function mnAnalyticsController($scope, mnAnalyticsService, $state, $http, mnPoller, mnBucketsService) {
    var vm = this;

    vm.computeOps = computeOps;
    vm.onSelectBucket = onSelectBucket;
    vm.onSelectNode = onSelectNode;

    activate();


    vm.isSpecificStats = !!$state.params.specificStat

    function activate() {
      if (!$state.params.specificStat) {
        new mnPoller($scope, function () {
          return mnAnalyticsService.prepareNodesList($state.params);
        })
        .subscribe("nodes", vm)
        .reloadOnScopeEvent("nodesChanged")
        .cycle();
      }

      //TODO separate dictionary from _uistats
      new mnPoller($scope, function (previousResult) {
        return mnAnalyticsService.getStats({$stateParams: $state.params, previousResult: previousResult});
      })
      .setInterval(function (response) {
        //TODO add error handler
        return response.isEmptyState ? 10000 : response.stats.nextReqAfter;
      })
      .subscribe("state", vm)
      .reloadOnScopeEvent("reloadAnalyticsPoller", vm);

      new mnPoller($scope, function () {
        return mnBucketsService.getBucketsByType().then(function (buckets) {
          var rv = {};
          rv.bucketsNames = buckets.byType.names;
          rv.bucketsNames.selected = $state.params.bucket;
          return rv;
        });
      })
      .subscribe("buckets", vm)
      .reloadOnScopeEvent("bucketUriChanged")
      .cycle();
    }
    function onSelectBucket(selectedBucket) {
      $state.go('app.admin.analytics.list.graph', {
        bucket: selectedBucket
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
